import Foundation
import Synchronization
import Testing
@testable import Support

/// Clock whose time a test moves by hand.
final class ReleaseTestClock: Support.Clock {
  private let value: Mutex<Date>

  init(_ now: Date = ReleaseFixture.start) { value = Mutex(now) }

  var now: Date { value.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    value.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

/// Scripted `ReleaseFetching`: answers in order (then fails like an offline Mac) and records each `If-None-Match`.
final class FakeReleaseFetcher: ReleaseFetching {
  enum Reply: Sendable {
    case response(ReleaseHTTPResponse)
    case offline
  }

  private let replies: Mutex<[Reply]>
  private let sent = Mutex<[String?]>([])

  init(_ replies: [Reply] = []) { self.replies = Mutex(replies) }

  var etagsSent: [String?] { sent.withLock { $0 } }
  var requestCount: Int { etagsSent.count }

  func fetchLatest(etag: String?) async throws -> ReleaseHTTPResponse {
    sent.withLock { $0.append(etag) }
    let reply = replies.withLock { $0.isEmpty ? Reply.offline : $0.removeFirst() }
    switch reply {
    case .response(let response): return response
    case .offline: throw URLError(.notConnectedToInternet)
    }
  }
}

enum ReleaseFixture {
  static let start = Date(timeIntervalSince1970: 1_790_000_000)
  static let day: TimeInterval = 24 * 60 * 60
  static let page = "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0"

  static func json(tag: String, url: String = page, draft: Bool = false, prerelease: Bool = false) -> Data {
    let object: [String: Any] = [
      "tag_name": tag, "html_url": url, "draft": draft, "prerelease": prerelease, "name": "Release \(tag)",
      "body": "Notes", "assets": [],
    ]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  static func ok(
    tag: String, url: String = page, draft: Bool = false, prerelease: Bool = false, etag: String? = "W/\"e1\""
  ) -> FakeReleaseFetcher.Reply {
    .response(
      ReleaseHTTPResponse(
        status: 200, etag: etag, body: json(tag: tag, url: url, draft: draft, prerelease: prerelease)))
  }

  static func status(_ code: Int, body: Data = Data(), etag: String? = nil) -> FakeReleaseFetcher.Reply {
    .response(ReleaseHTTPResponse(status: code, etag: etag, body: body))
  }

  static func info(_ version: String, page: String = page) throws -> AppReleaseInfo {
    AppReleaseInfo(version: version, pageURL: try #require(URL(string: page)))
  }
}

@Suite struct ReleaseCheckerTests {
  private func setUp(
    _ replies: [FakeReleaseFetcher.Reply], current: String = "1.1.0", name: String = #function
  ) throws -> (ReleaseChecker, FakeReleaseFetcher, ReleaseTestClock, URL) {
    let file = try makeTempDir(name).appendingPathComponent("release-check.json")
    let fetcher = FakeReleaseFetcher(replies)
    let clock = ReleaseTestClock()
    let checker = ReleaseChecker(stateFile: file, fetcher: fetcher, clock: clock, currentVersion: current)
    return (checker, fetcher, clock, file)
  }

  @Test func newerReleaseIsOffered() async throws {
    let (checker, fetcher, _, _) = try setUp([ReleaseFixture.ok(tag: "v1.2.0")])
    let expected = try ReleaseFixture.info("1.2.0")
    let outcome = await checker.checkIfDue()
    #expect(outcome.available == expected)
    #expect(fetcher.etagsSent == [nil])
  }

  @Test(arguments: ["1.1.0", "v1.1", "1.0.9", "v0.9.0", "1.1.0-rc.1"])
  func sameOrOlderReleaseIsNotOffered(tag: String) async throws {
    let (checker, fetcher, _, _) = try setUp([ReleaseFixture.ok(tag: tag)])
    #expect(await checker.checkIfDue().available == nil)
    #expect(fetcher.requestCount == 1)
  }

  @Test func versionsCompareNumericallyAfterStrippingV() async throws {
    let (checker, _, _, _) = try setUp([ReleaseFixture.ok(tag: "v1.10.0")], current: "1.9.3")
    #expect(await checker.checkIfDue().available?.version == "1.10.0")
  }

  @Test(arguments: [
    ("0.1.0", "v0.1.1", "0.1.1"), ("0.1.0", "v0.2", "0.2"), ("v0.1.0", "0.10.0", "0.10.0"),
    ("0.9.9", "v0.10.0", "0.10.0"), ("2.0.0", "V10.0.0", "10.0.0"), ("1.0.0-rc.1", "v1.0.0", "1.0.0"),
    ("0.1.0", "v0.1.0.1", "0.1.0.1"), ("0.1.0", " v0.2.0 ", "0.2.0"),
  ])
  func offersOnlyAStrictlyNewerVersion(current: String, tag: String, offered: String) async throws {
    let (checker, _, _, _) = try setUp([ReleaseFixture.ok(tag: tag)], current: current)
    #expect(await checker.checkIfDue().available?.version == offered)
  }

  @Test(arguments: [
    ("0.1.0", "v0.1"), ("0.1.0", "0.1.0+build.9"), ("v1.2.0", "1.2.0"), ("1.10.0", "v1.9.9"),
    ("0.1.0", "v0.0.99"), ("0.1.0.1", "v0.1.0"),
  ])
  func neverOffersTheSameOrAnOlderVersion(current: String, tag: String) async throws {
    let (checker, _, _, _) = try setUp([ReleaseFixture.ok(tag: tag)], current: current)
    #expect(await checker.checkIfDue().available == nil)
  }

  @Test(arguments: [(true, false), (false, true), (true, true)])
  func draftsAndPreReleasesAreIgnored(draft: Bool, prerelease: Bool) async throws {
    let reply = ReleaseFixture.ok(tag: "v9.0.0", draft: draft, prerelease: prerelease)
    let (checker, _, _, _) = try setUp([reply])
    #expect(await checker.checkIfDue().available == nil)
  }

  /// A SemVer pre-release tag is a pre-release even when GitHub's `prerelease` flag was left off.
  @Test(arguments: ["v9.0.0-beta.1", "9.0.0-rc.2+build.5"])
  func preReleaseTagIsIgnoredWithoutTheFlag(tag: String) async throws {
    let (checker, _, _, file) = try setUp([ReleaseFixture.ok(tag: tag)])
    #expect(await checker.checkIfDue().available == nil)
    #expect(ReleaseStateStore(file: file).load().latest == nil)
  }

  @Test func notModifiedReusesTheCachedRelease() async throws {
    let (checker, fetcher, clock, file) = try setUp([
      ReleaseFixture.ok(tag: "v1.2.0", etag: "W/\"abc\""), ReleaseFixture.status(304),
    ])
    let first = await checker.checkIfDue()
    clock.advance(by: ReleaseFixture.day)
    let second = await checker.checkIfDue()
    #expect(second.available == first.available)
    #expect(second.available?.version == "1.2.0")
    #expect(fetcher.etagsSent == [nil, "W/\"abc\""])
    let state = ReleaseStateStore(file: file).load()
    #expect(state.lastCheck == clock.now)
    #expect(state.etag == "W/\"abc\"")
  }

  @Test(arguments: [404, 403, 429, 500, 502])
  func errorStatusesOfferNothing(code: Int) async throws {
    let (checker, fetcher, _, _) = try setUp([ReleaseFixture.status(code)])
    #expect(await checker.checkIfDue().available == nil)
    #expect(fetcher.requestCount == 1)
  }

  @Test func networkErrorOffersNothing() async throws {
    let (checker, fetcher, _, _) = try setUp([.offline])
    #expect(await checker.checkIfDue().available == nil)
    #expect(fetcher.requestCount == 1)
  }

  @Test(arguments: [
    Data("not json".utf8), Data("{}".utf8), Data(#"{"html_url":"https://github.com/x"}"#.utf8),
    ReleaseFixture.json(tag: "nightly"), ReleaseFixture.json(tag: "../../evil"), ReleaseFixture.json(tag: "v2.0.0/../x"),
    ReleaseFixture.json(tag: "%2e%2e"), ReleaseFixture.json(tag: "v2.0.0?x=1"),
  ])
  func malformedPayloadOffersNothing(body: Data) async throws {
    let (checker, _, _, file) = try setUp([ReleaseFixture.status(200, body: body, etag: "W/\"x\"")])
    #expect(await checker.checkIfDue().available == nil)
    #expect(ReleaseStateStore(file: file).load().etag == nil)
  }

  /// `html_url` is never trusted: whatever it says, the page is the project's release page for the tag.
  @Test(arguments: [
    Data(#"{"tag_name":"v2.0.0"}"#.utf8), ReleaseFixture.json(tag: "v2.0.0", url: "https://evil.example/x"),
    ReleaseFixture.json(tag: "v2.0.0", url: "http://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v2.0.0"),
    ReleaseFixture.json(tag: "v2.0.0", url: "https://github.com/someone/else/releases/tag/v2.0.0"),
    ReleaseFixture.json(tag: "v2.0.0", url: "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/../../../evil"),
  ])
  func pageIsBuiltFromTheTagNotFromHTMLURL(body: Data) async throws {
    let (checker, _, _, file) = try setUp([ReleaseFixture.status(200, body: body, etag: "W/\"x\"")])
    let expected = try ReleaseFixture.info("2.0.0", page: "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v2.0.0")
    #expect(await checker.checkIfDue().available == expected)
    #expect(ReleaseStateStore(file: file).load().latest?.pageURL == expected.pageURL)
  }

  @Test func notFoundForgetsTheCachedRelease() async throws {
    let (checker, _, clock, file) = try setUp([ReleaseFixture.ok(tag: "v1.2.0"), ReleaseFixture.status(404)])
    #expect(await checker.checkIfDue().available != nil)
    clock.advance(by: ReleaseFixture.day)
    #expect(await checker.checkIfDue().available == nil)
    let state = ReleaseStateStore(file: file).load()
    #expect(state.latest == nil)
    #expect(state.etag == nil)
  }

  @Test(arguments: [
    ReleaseFixture.status(403), ReleaseFixture.status(429), ReleaseFixture.status(500),
    FakeReleaseFetcher.Reply.offline,
  ])
  func transientFailureKeepsTheCachedRelease(failure: FakeReleaseFetcher.Reply) async throws {
    let (checker, _, clock, _) = try setUp([ReleaseFixture.ok(tag: "v1.2.0"), failure])
    _ = await checker.checkIfDue()
    clock.advance(by: ReleaseFixture.day)
    #expect(await checker.checkIfDue().available?.version == "1.2.0")
  }

  @Test func requestsAtMostOncePerDay() async throws {
    let (checker, fetcher, clock, _) = try setUp([ReleaseFixture.ok(tag: "v1.2.0"), ReleaseFixture.status(304)])
    let first = await checker.checkIfDue()
    #expect(first.nextCheck == ReleaseFixture.start.addingTimeInterval(ReleaseFixture.day))
    #expect(first.wait == .seconds(86_400))
    clock.advance(by: ReleaseFixture.day - 60)
    let throttled = await checker.checkIfDue()
    #expect(fetcher.requestCount == 1)
    #expect(throttled.available == first.available)
    #expect(throttled.wait == .seconds(60))
    clock.advance(by: 60)
    _ = await checker.checkIfDue()
    #expect(fetcher.requestCount == 2)
  }

  @Test func overlappingChecksSendOneRequest() async throws {
    let (checker, fetcher, _, _) = try setUp([ReleaseFixture.ok(tag: "v1.2.0"), ReleaseFixture.ok(tag: "v1.3.0")])
    async let first = checker.checkIfDue()
    async let second = checker.checkIfDue()
    let outcomes = await [first, second]
    #expect(fetcher.requestCount == 1)
    #expect(outcomes.map { $0.available?.version } == ["1.2.0", "1.2.0"])
  }

  @Test func failedRequestIsThrottledToo() async throws {
    let (checker, fetcher, clock, _) = try setUp([.offline])
    _ = await checker.checkIfDue()
    clock.advance(by: 3600)
    _ = await checker.checkIfDue()
    #expect(fetcher.requestCount == 1)
  }

  @Test func waitNeverDropsBelowAMinute() async throws {
    let (checker, _, clock, _) = try setUp([.offline])
    _ = await checker.checkIfDue()
    clock.advance(by: ReleaseFixture.day - 5)
    #expect(await checker.checkIfDue().wait == .seconds(60))
  }

  @Test func lastCheckInTheFutureIsDue() async throws {
    let (checker, fetcher, _, file) = try setUp([ReleaseFixture.ok(tag: "v1.2.0")])
    let future = ReleaseCheckState(lastCheck: ReleaseFixture.start.addingTimeInterval(3600), etag: nil, latest: nil)
    ReleaseStateStore(file: file).save(future)
    _ = await checker.checkIfDue()
    #expect(fetcher.requestCount == 1)
  }

  @Test func cachedAnswersFromDiskWithoutNetwork() async throws {
    let (checker, fetcher, _, file) = try setUp([])
    let page = try #require(URL(string: ReleaseFixture.page))
    let latest = ReleaseCheckState.Release(version: "1.2.0", pageURL: page)
    ReleaseStateStore(file: file).save(ReleaseCheckState(lastCheck: ReleaseFixture.start, etag: "e", latest: latest))
    let expected = try ReleaseFixture.info("1.2.0")
    #expect(await checker.cached() == expected)
    #expect(fetcher.requestCount == 0)
  }

  @Test func cachedIgnoresATamperedPage() async throws {
    let (checker, _, _, file) = try setUp([])
    let page = try #require(URL(string: "https://evil.example/download"))
    let latest = ReleaseCheckState.Release(version: "9.0.0", pageURL: page)
    ReleaseStateStore(file: file).save(ReleaseCheckState(lastCheck: nil, etag: nil, latest: latest))
    #expect(await checker.cached() == nil)
  }

  @Test func unknownRunningVersionNeverOffers() async throws {
    let (checker, _, _, _) = try setUp([ReleaseFixture.ok(tag: "v99.0.0")], current: "dev")
    #expect(await checker.checkIfDue().available == nil)
  }
}
