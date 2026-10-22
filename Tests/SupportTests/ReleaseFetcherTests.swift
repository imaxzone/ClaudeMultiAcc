import Foundation
import Synchronization
import Testing
@testable import Support

/// Answers every request in-process with a canned 304 and remembers the request it saw (no network).
final class ReleaseStubProtocol: URLProtocol, @unchecked Sendable {
  static let seen = Mutex<[URLRequest]>([])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.seen.withLock { $0.append(request) }
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: ["ETag": "W/\"next\""])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite struct ReleaseFetcherTests {
  @Test func requestIsAnonymousAndMinimal() throws {
    let request = try GitHubReleaseFetcher.request(etag: nil, appVersion: "1.2.3")
    #expect(request.url?.absoluteString == "https://api.github.com/repos/imaxzone/ClaudeMultiAcc/releases/latest")
    #expect(request.httpMethod == "GET")
    #expect(request.timeoutInterval == 15)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.allHTTPHeaderFields == [
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": "ClaudeMultiAcc/1.2.3",
    ])
  }

  @Test func sendsTheStoredETag() throws {
    let request = try GitHubReleaseFetcher.request(etag: "W/\"abc\"", appVersion: "1.2.3")
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == "W/\"abc\"")
  }

  @Test(arguments: ["", "W/\"a\"\r\nCookie: x=1", String(repeating: "e", count: 300), "é"])
  func dropsUnsafeHeaderValues(etag: String) throws {
    let request = try GitHubReleaseFetcher.request(etag: etag, appVersion: "1.0\nEvil: 1")
    #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeMultiAcc/unknown")
    #expect(request.value(forHTTPHeaderField: "Evil") == nil)
  }

  @Test func sessionKeepsNoCookiesCacheOrCredentials() {
    let config = GitHubReleaseFetcher.configuration()
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
    #expect(config.httpCookieAcceptPolicy == .never)
    #expect(config.urlCache == nil)
    #expect(config.urlCredentialStorage == nil)
    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(config.timeoutIntervalForRequest == 15)
    #expect(config.timeoutIntervalForResource == 15)
    #expect(config.waitsForConnectivity == false)
  }

  @Test func mapsTheHTTPResponse() async throws {
    let config = GitHubReleaseFetcher.configuration()
    config.protocolClasses = [ReleaseStubProtocol.self]
    let fetcher = GitHubReleaseFetcher(appVersion: "0.1.0", session: URLSession(configuration: config))
    let response = try await fetcher.fetchLatest(etag: "W/\"prev\"")
    #expect(response.status == 304)
    #expect(response.etag == "W/\"next\"")
    #expect(response.body.isEmpty)
    let seen = try #require(ReleaseStubProtocol.seen.withLock { $0.last })
    #expect(seen.value(forHTTPHeaderField: "If-None-Match") == "W/\"prev\"")
    #expect(seen.value(forHTTPHeaderField: "User-Agent") == "ClaudeMultiAcc/0.1.0")
    #expect(seen.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(seen.value(forHTTPHeaderField: "Cookie") == nil)
  }
}
