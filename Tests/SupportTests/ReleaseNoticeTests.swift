import Foundation
import Synchronization
import Testing
@testable import Support

/// Records each requested pause and returns at once, moving `clock` (when given) by the pause; the `stopAfter`-th
/// pause throws, which ends the loop.
final class ReleaseTestSleeper: Sendable {
  private let pauses = Mutex<[Duration]>([])
  private let stopAfter: Int
  private let clock: ReleaseTestClock?

  init(stopAfter: Int, clock: ReleaseTestClock? = nil) {
    self.stopAfter = stopAfter
    self.clock = clock
  }

  var recorded: [Duration] { pauses.withLock { $0 } }

  func sleep(_ duration: Duration) async throws {
    let count = pauses.withLock {
      $0.append(duration)
      return $0.count
    }
    if count >= stopAfter { throw CancellationError() }
    clock?.advance(by: TimeInterval(duration.components.seconds))
  }
}

@MainActor
@Suite struct ReleaseNoticeTests {
  private struct Rig {
    let notice: ReleaseNotice
    let fetcher: FakeReleaseFetcher
    let sleeper: ReleaseTestSleeper
    let file: URL
  }

  private func rig(
    _ replies: [FakeReleaseFetcher.Reply], state: ReleaseCheckState? = nil, disabled: Bool = false,
    stopAfter: Int = 2, sleepMovesClock: Bool = false, name: String = #function
  ) throws -> Rig {
    let file = try makeTempDir(name).appendingPathComponent("release-check.json")
    if let state { ReleaseStateStore(file: file).save(state) }
    let fetcher = FakeReleaseFetcher(replies)
    let clock = ReleaseTestClock()
    let checker = ReleaseChecker(stateFile: file, fetcher: fetcher, clock: clock, currentVersion: "1.1.0")
    let sleeper = ReleaseTestSleeper(stopAfter: stopAfter, clock: sleepMovesClock ? clock : nil)
    let notice = ReleaseNotice(checker: checker, isDisabled: disabled) { try await sleeper.sleep($0) }
    return Rig(notice: notice, fetcher: fetcher, sleeper: sleeper, file: file)
  }

  private func cachedState(lastCheckAgo: TimeInterval, version: String) throws -> ReleaseCheckState {
    let page = try #require(URL(string: ReleaseFixture.page))
    return ReleaseCheckState(
      lastCheck: ReleaseFixture.start.addingTimeInterval(-lastCheckAgo), etag: "W/\"c\"",
      latest: ReleaseCheckState.Release(version: version, pageURL: page))
  }

  @Test func firstCheckAfterAMinuteThenDaily() async throws {
    let r = try rig([ReleaseFixture.ok(tag: "v1.2.0")])
    var changes = 0
    r.notice.onChange = { changes += 1 }
    let expected = try ReleaseFixture.info("1.2.0")
    r.notice.start()
    await r.notice.loop?.value
    #expect(r.notice.available == expected)
    #expect(changes == 1)
    #expect(r.fetcher.requestCount == 1)
    #expect(r.sleeper.recorded == [.seconds(60), .seconds(86_400)])
  }

  @Test func offersTheCachedReleaseAtOnceWithoutNetwork() async throws {
    let r = try rig([], state: try cachedState(lastCheckAgo: 2 * 3600, version: "1.2.0"), stopAfter: 1)
    var changes = 0
    r.notice.onChange = { changes += 1 }
    r.notice.start()
    await r.notice.loop?.value
    #expect(r.notice.available?.version == "1.2.0")
    #expect(changes == 1)
    #expect(r.fetcher.requestCount == 0)
  }

  @Test func recentCheckWaitsForTheRestOfTheDay() async throws {
    let r = try rig([], state: try cachedState(lastCheckAgo: 2 * 3600, version: "1.2.0"))
    r.notice.start()
    await r.notice.loop?.value
    #expect(r.fetcher.requestCount == 0)
    #expect(r.sleeper.recorded == [.seconds(60), .seconds(22 * 3600)])
  }

  @Test func noChangeCallbackWhenNothingChanges() async throws {
    let r = try rig([ReleaseFixture.ok(tag: "v1.1.0")])
    var changes = 0
    r.notice.onChange = { changes += 1 }
    r.notice.start()
    await r.notice.loop?.value
    #expect(r.notice.available == nil)
    #expect(changes == 0)
  }

  @Test func notModifiedKeepsTheCachedNotice() async throws {
    let r = try rig([ReleaseFixture.status(304)], state: try cachedState(lastCheckAgo: 2 * 86_400, version: "1.2.0"))
    var seen: [AppReleaseInfo?] = []
    r.notice.onChange = { seen.append(r.notice.available) }
    r.notice.start()
    await r.notice.loop?.value
    #expect(seen.map { $0?.version } == ["1.2.0"])
    #expect(r.fetcher.etagsSent == ["W/\"c\""])
  }

  @Test func picksUpANewerReleaseOnALaterDay() async throws {
    let replies = [ReleaseFixture.ok(tag: "v1.2.0"), ReleaseFixture.ok(tag: "v1.3.0")]
    let r = try rig(replies, stopAfter: 3, sleepMovesClock: true)
    var seen: [String?] = []
    r.notice.onChange = { seen.append(r.notice.available?.version) }
    r.notice.start()
    await r.notice.loop?.value
    #expect(seen == ["1.2.0", "1.3.0"])
    #expect(r.fetcher.etagsSent == [nil, "W/\"e1\""])
    #expect(r.sleeper.recorded == [.seconds(60), .seconds(86_400), .seconds(86_400)])
  }

  @Test func changeCallbackFiresWhenTheNoticeGoesAway() async throws {
    let r = try rig([ReleaseFixture.status(404)], state: try cachedState(lastCheckAgo: 2 * 86_400, version: "1.2.0"))
    var seen: [String?] = []
    r.notice.onChange = {
      MainActor.assertIsolated()
      seen.append(r.notice.available?.version)
    }
    r.notice.start()
    await r.notice.loop?.value
    #expect(seen == ["1.2.0", nil])
    #expect(r.notice.available == nil)
  }

  @Test func offlineLaunchKeepsTheCachedNoticeAndRetriesTomorrow() async throws {
    let r = try rig([.offline], state: try cachedState(lastCheckAgo: 2 * 86_400, version: "1.2.0"))
    var changes = 0
    r.notice.onChange = { changes += 1 }
    r.notice.start()
    await r.notice.loop?.value
    #expect(r.notice.available?.version == "1.2.0")
    #expect(changes == 1)
    #expect(r.fetcher.requestCount == 1)
    #expect(r.sleeper.recorded == [.seconds(60), .seconds(86_400)])
  }

  @Test func startTwiceRunsOneLoop() async throws {
    let r = try rig([ReleaseFixture.ok(tag: "v1.2.0")])
    r.notice.start()
    let first = r.notice.loop
    r.notice.start()
    #expect(r.notice.loop == first)
    await r.notice.loop?.value
    #expect(r.fetcher.requestCount == 1)
  }

  @Test func stopCancelsTheLoop() async throws {
    let r = try rig([ReleaseFixture.ok(tag: "v1.2.0")], stopAfter: 100)
    r.notice.start()
    let loop = r.notice.loop
    r.notice.stop()
    #expect(r.notice.loop == nil)
    await loop?.value
    #expect(loop?.isCancelled == true)
  }

  @Test func disabledNoticeNeverChecks() async throws {
    let r = try rig([ReleaseFixture.ok(tag: "v1.2.0")], disabled: true)
    r.notice.start()
    #expect(r.notice.loop == nil)
    #expect(r.notice.available == nil)
    #expect(r.fetcher.requestCount == 0)
    #expect(r.sleeper.recorded.isEmpty)
  }

  @Test func disabledNoticeIgnoresTheCache() async throws {
    let r = try rig([], state: try cachedState(lastCheckAgo: 3600, version: "1.2.0"), disabled: true)
    var changes = 0
    r.notice.onChange = { changes += 1 }
    r.notice.start()
    #expect(r.notice.loop == nil)
    #expect(r.notice.available == nil)
    #expect(changes == 0)
  }

  @Test(arguments: [
    (["CMACC_NO_UPDATE_CHECK": "1"], true), (["CMACC_NO_UPDATE_CHECK": "true"], true),
    (["CMACC_NO_UPDATE_CHECK": "YES"], true), (["CMACC_NO_UPDATE_CHECK": "0"], false),
    (["CMACC_NO_UPDATE_CHECK": ""], false), ([:], false),
  ])
  func environmentSwitch(environment: [String: String], disabled: Bool) {
    #expect(ReleaseNotice.isDisabled(environment: environment) == disabled)
  }

  @Test func liveNoticeHonoursTheEnvironment() throws {
    let dir = try makeTempDir()
    let paths = Paths(
      home: dir, dataDir: dir.appendingPathComponent("data"), logsDir: dir.appendingPathComponent("logs"))
    let notice = ReleaseNotice.live(paths: paths, environment: ["CMACC_NO_UPDATE_CHECK": "1"])
    notice.start()
    #expect(notice.loop == nil)
    #expect(notice.available == nil)
    #expect(!FileManager.default.fileExists(atPath: paths.releaseCheckFile.path))
  }

  @Test func runningVersionFallsBackToBuildInfo() {
    #expect(ReleaseNotice.runningVersion(infoDictionary: ["CFBundleShortVersionString": "2.3.4"]) == "2.3.4")
    #expect(ReleaseNotice.runningVersion(infoDictionary: nil) == BuildInfo.version)
    #expect(ReleaseNotice.runningVersion(infoDictionary: ["CFBundleShortVersionString": 7]) == BuildInfo.version)
  }
}
