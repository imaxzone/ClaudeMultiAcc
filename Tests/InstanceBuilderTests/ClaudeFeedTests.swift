import Foundation
import Synchronization
import Testing
@testable import InstanceBuilder

/// Answers every request in-process with the feed's real answer and remembers the requests it saw (no network).
final class ClaudeFeedAnswerStub: URLProtocol, @unchecked Sendable {
  static let seen = Mutex<[URLRequest]>([])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.seen.withLock { $0.append(request) }
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(ClaudeFeedTests.realAnswer.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// Fails every request in-process as if the Mac were offline.
final class ClaudeFeedOfflineStub: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
  override func stopLoading() {}
}

/// The Claude update feed: the request ClaudeMultiAcc sends and how the answer becomes the full zip to download.
@Suite struct ClaudeFeedTests {
  /// The feed's real answer on 22.10 (verbatim).
  static let realAnswer = #"""
    {"currentRelease":"3.1623.3","releases":[{"version":"3.1623.3","updateTo":{"name":"Claude 3.1623.3","version":"3.1623.3","pub_date":"2026-10-22T05:56:51.296476","url":"https://downloads.claude.ai/releases/darwin/arm64/3.1623.3/Claude-b5774a678cf8ba9882e729b5e981fe81e434c1be.zip","notes":"Production Release - No Notes","sha256":"9ba21b6538039729d0f92a4e56c06636077734856f0ca37819a6da6d9f2ed7a2","size":263612185,"delta":{"from_version":"3.1623.0","url":"https://downloads.claude.ai/releases/darwin/arm64/3.1623.3/Claude-b5774a678cf8ba9882e729b5e981fe81e434c1be-from-3.1623.0.delta","sha256":"35da093a49728497fdd1d7b50f33e23d42fe23a1069f04212af15b1323e9f211","size":16468994}}}]}
    """#
  static let zipURL =
    "https://downloads.claude.ai/releases/darwin/arm64/3.1623.3/Claude-b5774a678cf8ba9882e729b5e981fe81e434c1be.zip"
  static let deltaURL =
    "https://downloads.claude.ai/releases/darwin/arm64/3.1623.3/Claude-b5774a678cf8ba9882e729b5e981fe81e434c1be-from-3.1623.0.delta"
  static let sha256 = "9ba21b6538039729d0f92a4e56c06636077734856f0ca37819a6da6d9f2ed7a2"
  static let deviceId = "aaaaaaaa-0000-4000-8000-000000000042"

  /// `https://<user>[:<password>]@api.anthropic.com/x`, built so no address-like text sits in the source.
  static func withUserInfo(user: String, password: String? = nil) -> String {
    var components = URLComponents()
    (components.scheme, components.host, components.path) = ("https", "api.anthropic.com", "/x")
    (components.user, components.password) = (user, password)
    return components.string ?? ""
  }

  /// The real answer with `old` (which must occur in it) replaced by `new`.
  func realAnswer(replacing old: String, with new: String) -> Data {
    #expect(Self.realAnswer.contains(old), "fixture lacks \(old)")
    return Data(Self.realAnswer.replacingOccurrences(of: old, with: new).utf8)
  }

  /// A feed answer listing `versions` (each with a well-formed full zip) and naming `current` as the current release.
  func feed(current: String?, versions: [String]) -> Data {
    let entries = versions.map { v in
      #"{"version":"\#(v)","updateTo":{"version":"\#(v)","url":"https://downloads.claude.ai/releases/darwin/arm64/\#(v)/Claude-x.zip","sha256":"\#(Self.sha256)","size":1000}}"#
    }
    let head = current.map { #""currentRelease":"\#($0)","# } ?? ""
    return Data("{\(head)\"releases\":[\(entries.joined(separator: ","))]}".utf8)
  }

  /// The failure `body` throws, nil when it returns.
  func thrown(_ body: () throws -> ClaudeFeedAnswer) -> ClaudeUpdateFailure? {
    do {
      _ = try body()
      return nil
    } catch let failure as ClaudeUpdateFailure {
      return failure
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }

  /// The offered release, nil for `.none`.
  func offered(_ answer: ClaudeFeedAnswer) -> ClaudeRelease? {
    if case .available(let release) = answer { return release }
    return nil
  }

  func isBadAnswer(_ failure: ClaudeUpdateFailure?) -> Bool {
    if case .badAnswer = failure { return true }
    return false
  }

  // MARK: - Request

  @Test func theRequestCarriesExactlyDeviceVersionAndOS() throws {
    let request = try ClaudeFeed.request(
      current: "3.1623.0", deviceId: Self.deviceId.uppercased(), osVersion: "26.0.1", appVersion: "0.2.0")
    let url = try #require(request.url)
    let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(parts.scheme == "https")
    #expect(parts.host == "api.anthropic.com")
    #expect(parts.path == "/api/desktop/darwin/arm64/squirrel/update")
    #expect(parts.queryItems == [
      URLQueryItem(name: "device_id", value: Self.deviceId),
      URLQueryItem(name: "version", value: "3.1623.0"),
      URLQueryItem(name: "os_version", value: "26.0.1"),
    ])
    #expect(url.absoluteString == ClaudeFeed.endpoint + "?device_id=\(Self.deviceId)&version=3.1623.0&os_version=26.0.1")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.timeoutInterval == 30)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(request.allHTTPHeaderFields == ["Accept": "application/json", "User-Agent": "ClaudeMultiAcc/0.2.0"])

    let unsafe = try ClaudeFeed.request(
      current: "3.1623.0", deviceId: Self.deviceId, osVersion: "26.0", appVersion: "1.0\r\nCookie: x=1")
    #expect(unsafe.value(forHTTPHeaderField: "User-Agent") == "ClaudeMultiAcc/unknown")
    #expect(unsafe.value(forHTTPHeaderField: "Cookie") == nil)
  }

  @Test(arguments: [
    ("not-a-uuid", "3.1623.0", "26.0.1"),
    ("me@example.com", "3.1623.0", "26.0.1"),
    (ClaudeFeedTests.deviceId, "3.1623.0&x=1", "26.0.1"),
    (ClaudeFeedTests.deviceId, "3", "26.0.1"),
    (ClaudeFeedTests.deviceId, "3.1623.0", "26.0.1&x=1"),
    (ClaudeFeedTests.deviceId, "3.1623.0", ""),
    (ClaudeFeedTests.deviceId, "3.1623.0", "Version 26.0.1 (Build 25A1)"),
  ])
  func aRequestCarryingAnythingElseIsRefused(deviceId: String, current: String, osVersion: String) {
    #expect(throws: ClaudeUpdateFailure.self) {
      try ClaudeFeed.request(current: current, deviceId: deviceId, osVersion: osVersion, appVersion: "0.2.0")
    }
  }

  @Test func theSessionKeepsNoCookiesCacheOrCredentials() {
    let config = ClaudeFeedFetcher.configuration()
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
    #expect(config.httpCookieAcceptPolicy == .never)
    #expect(config.urlCache == nil)
    #expect(config.urlCredentialStorage == nil)
    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(config.timeoutIntervalForRequest == 30)
    #expect(config.timeoutIntervalForResource == 30)
    #expect(config.waitsForConnectivity == false)
  }

  // MARK: - Answer

  @Test func theRealAnswerOffersTheFullZip() throws {
    let answer = try ClaudeFeed.answer(status: 200, body: Data(Self.realAnswer.utf8), current: "3.1623.0")
    let url = try #require(URL(string: Self.zipURL))
    #expect(answer == .available(ClaudeRelease(version: "3.1623.3", url: url, sha256: Self.sha256, size: 263_612_185)))
  }

  @Test func noContentAndNotFoundMeanNone() throws {
    #expect(try ClaudeFeed.answer(status: 204, body: Data(), current: "3.1623.0") == .none)
    #expect(try ClaudeFeed.answer(status: 404, body: Data("Not Found".utf8), current: "3.1623.0") == .none)
  }

  @Test func aReleaseNotNewerThanCurrentIsNone() throws {
    let body = Data(Self.realAnswer.utf8)
    #expect(try ClaudeFeed.answer(status: 200, body: body, current: "3.1623.3") == .none)
    #expect(try ClaudeFeed.answer(status: 200, body: body, current: "3.1700.0") == .none)
    // Nothing would be downloaded, so a bad url on a release that is not newer is no failure either.
    let elsewhere = realAnswer(replacing: Self.zipURL, with: "https://example.com/Claude.zip")
    #expect(try ClaudeFeed.answer(status: 200, body: elsewhere, current: "3.1623.3") == .none)
  }

  @Test func theCurrentReleaseIsChosenElseTheHighest() throws {
    let named = try ClaudeFeed.answer(
      status: 200, body: feed(current: "3.1623.3", versions: ["3.1700.0", "3.1623.3"]), current: "3.1623.0")
    #expect(offered(named)?.version == "3.1623.3")
    let highest = try ClaudeFeed.answer(
      status: 200, body: feed(current: nil, versions: ["3.1623.3", "3.1700.1", "3.1650.0"]), current: "3.1623.0")
    #expect(offered(highest)?.version == "3.1700.1")
    let unknown = try ClaudeFeed.answer(
      status: 200, body: feed(current: "9.9.9", versions: ["3.1650.0", "3.1623.3"]), current: "3.1623.0")
    #expect(offered(unknown)?.version == "3.1650.0")
    #expect(try ClaudeFeed.answer(status: 200, body: feed(current: nil, versions: []), current: "3.1623.0") == .none)
  }

  @Test func anotherHostOrADeltaPathIsUntrusted() {
    let urls = [
      Self.deltaURL,
      "https://example.com/releases/darwin/arm64/3.1623.3/Claude.zip",
      "http://downloads.claude.ai/releases/darwin/arm64/3.1623.3/Claude.zip",
      "https://downloads.claude.ai:8443/releases/darwin/arm64/3.1623.3/Claude.zip",
      "https://downloads.claude.ai.example.com/releases/darwin/arm64/3.1623.3/Claude.zip",
      "https://downloads.claude.ai/releases/win32/x64/3.1623.3/Claude.zip",
      "https://downloads.claude.ai/releases/darwin/../win32/Claude.zip",
      "not a url",
    ]
    for url in urls {
      let body = realAnswer(replacing: #""url":"\#(Self.zipURL)""#, with: #""url":"\#(url)""#)
      let failure = thrown { try ClaudeFeed.answer(status: 200, body: body, current: "3.1623.0") }
      #expect(failure == .untrustedURL(url), "\(url)")
    }
  }

  @Test func badChecksumSizeOrVersionIsABadAnswer() throws {
    let bodies = [
      realAnswer(replacing: Self.sha256, with: String(Self.sha256.dropLast())),
      realAnswer(replacing: Self.sha256, with: Self.sha256 + "0"),
      realAnswer(replacing: Self.sha256, with: "g" + Self.sha256.dropFirst()),
      realAnswer(replacing: Self.sha256, with: ""),
      realAnswer(replacing: #""size":263612185"#, with: #""size":0"#),
      realAnswer(replacing: #""size":263612185"#, with: #""size":-1"#),
      realAnswer(replacing: #""size":263612185"#, with: #""size":2000000001"#),
      realAnswer(replacing: #""version":"3.1623.3","pub_date""#, with: #""version":"3.1623.3.1.2","pub_date""#),
      realAnswer(replacing: #""version":"3.1623.3","pub_date""#, with: #""version":"../../3.1623.3","pub_date""#),
      realAnswer(replacing: #""version":"3.1623.3","pub_date""#, with: #""version":"4","pub_date""#),
    ]
    for (index, body) in bodies.enumerated() {
      let failure = thrown { try ClaudeFeed.answer(status: 200, body: body, current: "3.1623.0") }
      #expect(isBadAnswer(failure), "body \(index): \(String(describing: failure))")
    }
    let upper = realAnswer(replacing: Self.sha256, with: Self.sha256.uppercased())
    let answer = try ClaudeFeed.answer(status: 200, body: upper, current: "3.1623.0")
    #expect(offered(answer)?.sha256 == Self.sha256)
    let largest = realAnswer(replacing: #""size":263612185"#, with: #""size":2000000000"#)
    let biggest = try ClaudeFeed.answer(status: 200, body: largest, current: "3.1623.0")
    #expect(offered(biggest)?.size == ClaudeFeed.maxArchiveSize)
  }

  @Test func anUnreadableBodyIsABadAnswer() {
    let bodies = [
      Data(), Data("{".utf8), Data("[]".utf8), Data(#"{"releases":"x"}"#.utf8),
      Data(#"{"releases":[{"version":"3.1623.3"}]}"#.utf8),
      Data(repeating: 0x20, count: ClaudeFeed.maxBodyBytes + 1),
    ]
    for body in bodies {
      #expect(isBadAnswer(thrown { try ClaudeFeed.answer(status: 200, body: body, current: "3.1623.0") }))
    }
  }

  @Test(arguments: [201, 301, 302, 304, 400, 403, 429, 500, 503])
  func otherStatusesAreBadAnswers(status: Int) {
    let failure = thrown { try ClaudeFeed.answer(status: status, body: Data(Self.realAnswer.utf8), current: "3.1623.0") }
    #expect(failure == .badAnswer("HTTP \(status)"))
  }

  // MARK: - Fetcher

  @Test func redirectsStayOnApiAnthropicCom() async throws {
    let allowed = ["https://api.anthropic.com/api/desktop/darwin/arm64/squirrel/update?a=1", "https://API.Anthropic.com/x"]
    for text in allowed {
      #expect(ClaudeFeedRedirects.allows(URL(string: text)), "\(text)")
    }
    let refused = [
      "http://api.anthropic.com/x", "https://api.anthropic.com:8443/x", Self.withUserInfo(user: "user"),
      Self.withUserInfo(user: "user", password: "pw"), "https://api.anthropic.com.example.com/x",
      "https://releases.claude.com/x",
      "https://downloads.claude.ai/releases/darwin/arm64/3.1623.3/Claude.zip", "https://anthropic.com/x",
    ]
    for text in refused {
      #expect(!ClaudeFeedRedirects.allows(URL(string: text)), "\(text)")
    }
    #expect(!ClaudeFeedRedirects.allows(nil))

    let session = URLSession(configuration: ClaudeFeedFetcher.configuration())
    defer { session.invalidateAndCancel() }
    let original = try #require(URL(string: ClaudeFeed.endpoint))
    let task = session.dataTask(with: original)
    let redirect = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
    let away = URLRequest(url: try #require(URL(string: "https://example.com/update")))
    #expect(await ClaudeFeedRedirects().urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: away) == nil)
    let same = URLRequest(url: try #require(URL(string: "https://api.anthropic.com/api/other")))
    let followed = await ClaudeFeedRedirects().urlSession(
      session, task: task, willPerformHTTPRedirection: redirect, newRequest: same)
    #expect(followed?.url == same.url)
  }

  @Test func theFetcherMapsTheAnswerAndTransportErrors() async throws {
    let config = ClaudeFeedFetcher.configuration()
    config.protocolClasses = [ClaudeFeedAnswerStub.self]
    let fetcher = ClaudeFeedFetcher(appVersion: "0.2.0", session: URLSession(configuration: config))
    let answer = try await fetcher.latest(current: "3.1623.0", deviceId: Self.deviceId, osVersion: "26.0.1")
    #expect(offered(answer)?.version == "3.1623.3")
    let seen = try #require(ClaudeFeedAnswerStub.seen.withLock { $0.last })
    #expect(seen.value(forHTTPHeaderField: "User-Agent") == "ClaudeMultiAcc/0.2.0")
    #expect(seen.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(seen.value(forHTTPHeaderField: "Authorization") == nil)

    let offline = ClaudeFeedFetcher.configuration()
    offline.protocolClasses = [ClaudeFeedOfflineStub.self]
    let failing = ClaudeFeedFetcher(appVersion: "0.2.0", session: URLSession(configuration: offline))
    do {
      _ = try await failing.latest(current: "3.1623.0", deviceId: Self.deviceId, osVersion: "26.0.1")
      Issue.record("an offline fetch returned an answer")
    } catch let failure as ClaudeUpdateFailure {
      guard case .network = failure else {
        Issue.record("expected .network, got \(failure)")
        return
      }
    }
  }
}
