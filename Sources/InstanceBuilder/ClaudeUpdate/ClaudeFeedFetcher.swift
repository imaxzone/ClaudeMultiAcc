import Foundation
import Support

/// Asks Anthropic's Claude update feed what is newer: one anonymous, cookie-less, cache-less GET
/// (`ClaudeFeed.request`). Redirects are followed only within https://api.anthropic.com (`ClaudeFeedRedirects`).
/// Throws `ClaudeUpdateFailure`: `.network` for transport errors, `.badAnswer` and `.untrustedURL` from the answer.
public struct ClaudeFeedFetcher: ClaudeFeedFetching {
  private let appVersion: String
  private let session: URLSession

  public init(appVersion: String, session: URLSession = ClaudeFeedFetcher.makeSession()) {
    self.appVersion = appVersion
    self.session = session
  }

  /// The ephemeral session below with the redirect guard as its delegate.
  public static func makeSession() -> URLSession {
    URLSession(configuration: configuration(), delegate: ClaudeFeedRedirects(), delegateQueue: nil)
  }

  /// Ephemeral session that stores and sends no cookies, credentials or cached responses.
  public static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = ClaudeFeed.timeout
    config.timeoutIntervalForResource = ClaudeFeed.timeout
    config.waitsForConnectivity = false
    return config
  }

  public func latest(current: String, deviceId: String, osVersion: String) async throws -> ClaudeFeedAnswer {
    let request = try ClaudeFeed.request(
      current: current, deviceId: deviceId, osVersion: osVersion, appVersion: appVersion)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request, delegate: ClaudeFeedRedirects())
    } catch {
      throw ClaudeUpdateFailure.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse else { throw ClaudeUpdateFailure.badAnswer("not HTTP") }
    guard ClaudeFeedRedirects.allows(http.url) else {
      throw ClaudeUpdateFailure.untrustedURL(ClaudeFeed.excerpt(http.url?.absoluteString ?? "?"))
    }
    return try ClaudeFeed.answer(status: http.statusCode, body: data, current: current)
  }
}

/// Follows a redirect only to https://api.anthropic.com. Any other target ends the request with the redirect
/// response itself, which `ClaudeFeed.answer` reports as a bad answer (`HTTP 3xx`). Set as both the session's and
/// the task's delegate.
final class ClaudeFeedRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  static let host = "api.anthropic.com"

  static func allows(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", url.host()?.lowercased() == host, url.port == nil,
      url.user() == nil, url.password() == nil
    else { return false }
    return true
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard Self.allows(request.url) else {
      AppLog.logger("claude-update").notice("Claude feed: refused a redirect away from \(Self.host, privacy: .public)")
      return nil
    }
    return request
  }
}
