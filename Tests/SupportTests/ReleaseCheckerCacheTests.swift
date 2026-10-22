import Foundation
import Testing
@testable import Support

/// The once-a-day gate, the `ETag` round trip and what a relaunch (a new checker on the same file) remembers.
@Suite struct ReleaseCheckerCacheTests {
  /// Seconds since the last request (nil: never asked; negative: the stamp lies in the future) and whether a request
  /// is due.
  static let gate: [(TimeInterval?, Bool)] = [
    (nil, true), (0, false), (3600, false), (86_399, false), (86_400, true), (90_000, true), (-1, true),
  ]

  private func stateFile(_ name: String = #function) throws -> URL {
    try makeTempDir(name).appendingPathComponent("release-check.json")
  }

  private func checker(_ fetcher: FakeReleaseFetcher, file: URL, clock: ReleaseTestClock) -> ReleaseChecker {
    ReleaseChecker(stateFile: file, fetcher: fetcher, clock: clock, currentVersion: "1.1.0")
  }

  /// Runs one check per reply, a day apart, on one checker; returns the fetcher and each outcome's version.
  private func daily(_ replies: [FakeReleaseFetcher.Reply], file: URL) async -> (FakeReleaseFetcher, [String?]) {
    let clock = ReleaseTestClock()
    let fetcher = FakeReleaseFetcher(replies)
    let checker = checker(fetcher, file: file, clock: clock)
    var versions: [String?] = []
    for _ in replies {
      versions.append(await checker.checkIfDue().available?.version)
      clock.advance(by: ReleaseFixture.day)
    }
    return (fetcher, versions)
  }

  @Test(arguments: ReleaseCheckerCacheTests.gate)
  func requestIsDueOncePerDay(sinceLast: TimeInterval?, due: Bool) {
    let lastCheck = sinceLast.map { ReleaseFixture.start.addingTimeInterval(-$0) }
    #expect(ReleaseChecker.isDue(lastCheck: lastCheck, now: ReleaseFixture.start) == due)
  }

  @Test func relaunchWithinADayNeitherReasksNorForgets() async throws {
    let file = try stateFile()
    let clock = ReleaseTestClock()
    let before = FakeReleaseFetcher([ReleaseFixture.ok(tag: "v1.2.0", etag: "W/\"r1\"")])
    _ = await checker(before, file: file, clock: clock).checkIfDue()
    clock.advance(by: 3600)
    let after = FakeReleaseFetcher([ReleaseFixture.ok(tag: "v9.0.0")])
    let relaunched = checker(after, file: file, clock: clock)
    let expected = try ReleaseFixture.info("1.2.0")
    #expect(await relaunched.cached() == expected)
    let outcome = await relaunched.checkIfDue()
    #expect(outcome.available == expected)
    #expect(outcome.nextCheck == ReleaseFixture.start.addingTimeInterval(ReleaseFixture.day))
    #expect(outcome.wait == .seconds(23 * 3600))
    #expect(after.requestCount == 0)
  }

  @Test func relaunchAfterADaySendsTheStoredETag() async throws {
    let file = try stateFile()
    let clock = ReleaseTestClock()
    let before = FakeReleaseFetcher([ReleaseFixture.ok(tag: "v1.2.0", etag: "W/\"r1\"")])
    _ = await checker(before, file: file, clock: clock).checkIfDue()
    clock.advance(by: ReleaseFixture.day)
    let after = FakeReleaseFetcher([ReleaseFixture.status(304)])
    #expect(await checker(after, file: file, clock: clock).checkIfDue().available?.version == "1.2.0")
    #expect(after.etagsSent == ["W/\"r1\""])
    let state = ReleaseStateStore(file: file).load()
    #expect(state.lastCheck == clock.now)
    #expect(state.etag == "W/\"r1\"")
  }

  @Test func notModifiedWithNothingCachedOffersNothing() async throws {
    let file = try stateFile()
    let fetcher = FakeReleaseFetcher([ReleaseFixture.status(304, etag: "W/\"z\"")])
    #expect(await checker(fetcher, file: file, clock: ReleaseTestClock()).checkIfDue().available == nil)
    let stored = ReleaseStateStore(file: file).load()
    #expect(stored == ReleaseCheckState(lastCheck: ReleaseFixture.start, etag: nil, latest: nil))
  }

  @Test func newerAnswerReplacesTheETag() async throws {
    let (fetcher, versions) = await daily(
      [
        ReleaseFixture.ok(tag: "v1.2.0", etag: "W/\"e1\""), ReleaseFixture.ok(tag: "v1.3.0", etag: "W/\"e2\""),
        ReleaseFixture.status(304),
      ], file: try stateFile())
    #expect(versions == ["1.2.0", "1.3.0", "1.3.0"])
    #expect(fetcher.etagsSent == [nil, "W/\"e1\"", "W/\"e2\""])
  }

  @Test func answerWithoutETagSendsNoneNextTime() async throws {
    let (fetcher, versions) = await daily(
      [ReleaseFixture.ok(tag: "v1.2.0", etag: nil), ReleaseFixture.ok(tag: "v1.2.0")], file: try stateFile())
    #expect(versions == ["1.2.0", "1.2.0"])
    #expect(fetcher.etagsSent == [nil, nil])
  }

  @Test(arguments: [("v2.0.0-beta.1", true), ("v2.0.0-beta.1", false), ("v2.0.0", true)])
  func preReleaseAnswerKeepsTheStableNoticeButDropsTheETag(tag: String, flagged: Bool) async throws {
    let (fetcher, versions) = await daily(
      [
        ReleaseFixture.ok(tag: "v1.2.0", etag: "W/\"e1\""), ReleaseFixture.ok(tag: tag, prerelease: flagged),
        ReleaseFixture.status(304),
      ], file: try stateFile())
    #expect(versions == ["1.2.0", "1.2.0", "1.2.0"])
    #expect(fetcher.etagsSent == [nil, "W/\"e1\"", nil])
  }

  @Test func oversizedAnswerIsRefusedUnread() async throws {
    let body = Data(repeating: 0x20, count: ReleasePayload.maxBytes + 1)
    let file = try stateFile()
    let (_, versions) = await daily([ReleaseFixture.status(200, body: body, etag: "W/\"big\"")], file: file)
    #expect(versions == [nil])
    #expect(ReleaseStateStore(file: file).load().etag == nil)
  }

  @Test func unwritableStateStillAnswersAndThrottlesInMemory() async throws {
    let dir = try makeTempDir()
    let file = dir.appendingPathComponent("release-check.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let fetcher = FakeReleaseFetcher([ReleaseFixture.ok(tag: "v1.2.0")])
    let outcome = await checker(fetcher, file: file, clock: ReleaseTestClock()).checkIfDue()
    #expect(outcome.available?.version == "1.2.0")
    #expect(outcome.wait == .seconds(86_400))
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}
