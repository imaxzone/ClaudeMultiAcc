import Foundation
import Testing
@testable import Support

/// The release page the menu opens is built from the validated tag, never taken from GitHub's `html_url`.
@Suite struct ReleasePageTests {
  static let canonical = "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0"

  @Test(arguments: ["v1.2.0", "1.2.0", "V1.2", "v2.0.0-rc.1", "1.5.0-beta.2+build.7"])
  func buildsThePageFromAVersionTag(tag: String) throws {
    let url = try #require(ReleasePage.url(forTag: tag))
    #expect(url.absoluteString == "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/" + tag)
    #expect(ReleasePage.isAllowed(url))
  }

  @Test(arguments: [
    "", "nightly", ".", "..", "../x", "v1.2.0/../../evil", "%2e%2e", "v1.0.0%2F..", "v1.0.0?x=1", "v1.0.0#f",
    "v1.0.0\n", "v 1.0.0", "v1.0.0/", "v1..0", "1.2.3+build/x", "v1.0.0\u{0}", "v１.0.0",
  ])
  func refusesATagThatIsNotJustAVersion(tag: String) {
    #expect(ReleasePage.url(forTag: tag) == nil)
  }

  @Test func dropsSurroundingSpacesLikeReleaseVersion() {
    #expect(ReleasePage.url(forTag: " v1.2.0 ")?.absoluteString == Self.canonical)
  }

  @Test func acceptsTheCanonicalPageAndGitHubsOwnCase() throws {
    #expect(ReleasePage.isAllowed(try #require(URL(string: Self.canonical))))
    let upper = ReleasePage.base.replacingOccurrences(of: "ClaudeMultiAcc", with: "CLAUDEMULTIACC") + "v1.2.0"
    #expect(ReleasePage.isAllowed(try #require(URL(string: upper))))
  }

  @Test(arguments: [
    "http://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0",
    "https://github.com.evil.example/x/ClaudeMultiAcc/releases/tag/v1.2.0",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0?download=1",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0#x",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/../../../evil/repo",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/%2e%2e/%2e%2e/evil",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0/../../../../evil",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/nightly",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/download/v1.2.0/ClaudeMultiAcc.dmg",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases",
    "https://github.com/someone/else/releases/tag/v1.2.0",
    "https://evil.example/download",
  ])
  func refusesEverythingElse(text: String) throws {
    #expect(!ReleasePage.isAllowed(try #require(URL(string: text))))
  }

  @Test func refusesCredentialsAndPorts() throws {
    var withUser = try #require(URLComponents(string: Self.canonical))
    withUser.user = "user"
    withUser.password = "pw"
    var withPort = try #require(URLComponents(string: Self.canonical))
    withPort.port = 443
    for components in [withUser, withPort] {
      #expect(!ReleasePage.isAllowed(try #require(components.url)))
    }
  }
}

/// Redirects of the release request are followed only within https://api.github.com.
@Suite struct ReleaseRedirectTests {
  func decide(_ target: String) async throws -> URLRequest? {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let original = try #require(URL(string: GitHubReleaseFetcher.endpoint))
    let task = session.dataTask(with: original) // never resumed: no network
    let response = try #require(HTTPURLResponse(url: original, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: nil))
    let next = URLRequest(url: try #require(URL(string: target)))
    return await SameHostRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next)
  }

  @Test func followsARedirectWithinTheAPIHost() async throws {
    let target = "https://api.github.com/repositories/123/releases/latest"
    #expect(try await decide(target)?.url?.absoluteString == target)
  }

  @Test(arguments: [
    "https://evil.example/releases/latest", "http://api.github.com/repos/x/y/releases/latest",
    "https://api.github.com.evil.example/x", "https://api.github.com:8443/x",
    "https://github.com/imaxzone/ClaudeMultiAcc/releases/latest", "file:///etc/passwd",
  ])
  func refusesARedirectAnywhereElse(target: String) async throws {
    #expect(try await decide(target) == nil)
  }

  @Test func refusesARedirectWithCredentials() async throws {
    var components = try #require(URLComponents(string: "https://api.github.com/x"))
    components.user = "u"
    components.password = "p"
    #expect(try await decide(try #require(components.url?.absoluteString)) == nil)
  }

  @Test func fetcherRefusesAnAnswerFromAnotherHost() async throws {
    let config = GitHubReleaseFetcher.configuration()
    config.protocolClasses = [ForeignHostStubProtocol.self]
    let fetcher = GitHubReleaseFetcher(appVersion: "0.1.0", session: URLSession(configuration: config))
    await #expect(throws: ReleaseFetchError.unexpectedHost) { _ = try await fetcher.fetchLatest(etag: nil) }
  }
}

/// Answers with a 200 whose URL is on another host, as if a redirect had been followed there (no network).
final class ForeignHostStubProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard
      let url = URL(string: "https://evil.example/releases/latest"),
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(#"{"tag_name":"v9.0.0"}"#.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
