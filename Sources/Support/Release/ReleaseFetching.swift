import Foundation

/// One HTTP answer from the release endpoint, uninterpreted.
public struct ReleaseHTTPResponse: Sendable, Equatable {
  public let status: Int
  public let etag: String?
  public let body: Data

  public init(status: Int, etag: String?, body: Data) {
    self.status = status
    self.etag = etag
    self.body = body
  }
}

/// Fetches the latest ClaudeMultiAcc release; injected so tests never touch the network.
public protocol ReleaseFetching: Sendable {
  /// GETs the latest release, sending `If-None-Match: etag` when given. Throws on transport errors only.
  func fetchLatest(etag: String?) async throws -> ReleaseHTTPResponse
}

public enum ReleaseFetchError: Error, Equatable {
  case badEndpoint
  case notHTTP
  /// The answer came from somewhere other than https://api.github.com.
  case unexpectedHost
}

/// The app's only network request: an anonymous, cookie-less, cache-less GET of the public GitHub releases API.
/// Redirects are followed only within https://api.github.com (`SameHostRedirects`).
public struct GitHubReleaseFetcher: ReleaseFetching {
  public static let endpoint = "https://api.github.com/repos/imaxzone/ClaudeMultiAcc/releases/latest"
  public static let timeout: TimeInterval = 15
  static let maxHeaderLength = 200

  private let appVersion: String
  private let session: URLSession

  public init(appVersion: String, session: URLSession = GitHubReleaseFetcher.makeSession()) {
    self.appVersion = appVersion
    self.session = session
  }

  /// The ephemeral session below with the redirect guard as its delegate.
  public static func makeSession() -> URLSession {
    URLSession(configuration: configuration(), delegate: SameHostRedirects(), delegateQueue: nil)
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
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    config.waitsForConnectivity = false
    return config
  }

  /// The request with exactly the documented GitHub headers; header values that are not plain printable ASCII
  /// are dropped (`If-None-Match`) or replaced (`User-Agent: ClaudeMultiAcc/unknown`).
  static func request(etag: String?, appVersion: String) throws -> URLRequest {
    guard let url = URL(string: endpoint) else { throw ReleaseFetchError.badEndpoint }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let version = isSafeHeaderValue(appVersion) ? appVersion : "unknown"
    request.setValue("ClaudeMultiAcc/\(version)", forHTTPHeaderField: "User-Agent")
    if let etag, isSafeHeaderValue(etag) {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    }
    return request
  }

  static func isSafeHeaderValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= maxHeaderLength && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
  }

  public func fetchLatest(etag: String?) async throws -> ReleaseHTTPResponse {
    let request = try Self.request(etag: etag, appVersion: appVersion)
    let (data, response) = try await session.data(for: request, delegate: SameHostRedirects())
    guard let http = response as? HTTPURLResponse else { throw ReleaseFetchError.notHTTP }
    guard SameHostRedirects.allows(http.url) else { throw ReleaseFetchError.unexpectedHost }
    let tag = http.value(forHTTPHeaderField: "ETag").flatMap { Self.isSafeHeaderValue($0) ? $0 : nil }
    return ReleaseHTTPResponse(status: http.statusCode, etag: tag, body: data)
  }
}

/// Follows a redirect only to https://api.github.com (GitHub answers a renamed repository with a 301 there). Any
/// other target ends the request with the redirect response itself, which the checker treats as an unexpected
/// status. Set as both the session's and the task's delegate.
final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  static let host = "api.github.com"

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
      AppLog.logger("release-check").notice("Release check: refused a redirect away from \(Self.host, privacy: .public)")
      return nil
    }
    return request
  }
}
