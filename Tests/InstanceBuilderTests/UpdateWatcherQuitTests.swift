import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// `cloneDidQuit(bundleId:)` and `applyPendingNow()`: a verified build waiting for a running clone is swapped in as
/// soon as that clone quits, not at the next hourly pass.
@Suite(.serialized) struct UpdateWatcherQuitTests {
  private let work = "com.imaxzone.claude.work"

  /// Creates `url` and takes an exclusive flock on it, as a launcher (or another pass) does.
  private func holdLock(_ url: URL) throws -> Int32 {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fd = open(url.path, O_RDWR)
    try #require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
    return fd
  }

  /// A first pass with `work` running leaves its verified build in `pendingBuild`.
  private func fixtureWithPendingWork(_ name: String = #function) async throws -> WatcherFixture {
    let f = try await makeWatcherFixture(WatcherKnobs(), name)
    #expect(decisionLines(await f.watcher.handleOfficialChange()) == ["skip second", "pending work", "swap home"])
    return f
  }

  @Test func aQuitCloneGetsItsPendingBuildRightAway() async throws {
    let f = try await fixtureWithPendingWork()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let staged = try #require(try await f.pending("work"))
    f.running.set([])
    let decisions = await f.watcher.cloneDidQuit(bundleId: work)
    #expect(decisionLines(decisions) == ["skip second", "swap work", "skip home"], "\(decisions.map(\.line))")
    #expect(f.marker("Claude Work") == "new")
    #expect(try await f.pending("work") == nil)
    #expect(!FileManager.default.fileExists(atPath: staged))
    #expect(f.builds.count == 2)
    #expect(f.sleeps.all.isEmpty)
    let log = f.updatesLog
    let quit = try #require(log.range(of: "quit work: pending build, applying\n"))
    let swap = try #require(log.range(of: "swap work: 1.0.0 → 2.0.0 from pending build"))
    #expect(quit.upperBound <= swap.lowerBound)
  }

  /// Unknown apps, the official app, a legacy clone (even with a pendingBuild) and a cmacc clone without one.
  @Test(arguments: ["com.example.other", CloneSpec.vendorBundleId, CloneSpec.legacySecondBundleId, "com.imaxzone.claude.home"])
  func otherAppsQuittingDoNothing(bundleId: String) async throws {
    let f = try await fixtureWithPendingWork("other-\(bundleId)")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = InstanceStore(paths: f.paths)
    let staged = try await f.pending("work")
    let second = try #require(try await store.load().first { $0.slug.raw == "second" })
    _ = try await store.upsert(second.withBuild(builtBy: second.builtBy, pendingBuild: staged))
    f.running.set([])
    let logBefore = f.updatesLog
    let decisions = await f.watcher.cloneDidQuit(bundleId: bundleId)
    #expect(decisions.isEmpty)
    #expect(f.updatesLog == logBefore)
    #expect(f.builds.count == 2)
    #expect(f.marker("Claude Work") == "old" && f.marker("Claude 2nd") == "old")
    #expect(try await f.pending("work") == staged)
    #expect(f.sleeps.all.isEmpty)
  }

  /// Right after the quit the process, or an Electron helper holding `.clone.lock`, lingers; the swap waits for it.
  @Test(arguments: ["process", "lock"])
  func theSwapWaitsUntilTheQuitCloneSettles(holder: String) async throws {
    let f = try await fixtureWithPendingWork("settles-\(holder)")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let fd = holder == "lock" ? try holdLock(f.root.appendingPathComponent("profiles/work/.clone.lock")) : -1
    defer { if fd >= 0 { close(fd) } }
    let running = f.running
    if holder == "lock" { running.set([]) }
    f.sleeps.onSleep { call in
      guard call == 3 else { return }
      if holder == "lock" { flock(fd, LOCK_UN) } else { running.set([]) }
    }
    let decisions = await f.watcher.cloneDidQuit(bundleId: work)
    #expect(decisionLines(decisions) == ["skip second", "swap work", "skip home"], "\(decisions.map(\.line))")
    #expect(f.sleeps.all == Array(repeating: UpdateWatcher.idlePoll, count: 3))
    #expect(f.marker("Claude Work") == "new")
    #expect(try await f.pending("work") == nil)
  }

  @Test func aCloneThatKeepsRunningKeepsItsBuildPending() async throws {
    let f = try await fixtureWithPendingWork()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let staged = try #require(try await f.pending("work"))
    let decisions = await f.watcher.cloneDidQuit(bundleId: work)
    #expect(decisions == [UpdateDecision(
      slug: "work", action: .pendingWaiting, detail: "still running 30 s after quit; build waits at \(staged)")])
    #expect(f.sleeps.all == Array(repeating: UpdateWatcher.idlePoll, count: Int(UpdateWatcher.quitSettle / UpdateWatcher.idlePoll)))
    #expect(f.marker("Claude Work") == "old")
    #expect(try await f.pending("work") == staged)
    #expect(f.builds.count == 2)
    #expect(f.updatesLog.hasSuffix("pending-waiting work: still running 30 s after quit; build waits at \(staged)\n"))
    #expect(!f.updatesLog.contains("quit work"))
  }

  /// Another process holds `update.lock`: retried after the injected sleep until this caller's own pass runs.
  @Test func applyPendingNowOutlastsAHeldUpdateLock() async throws {
    let f = try await makeWatcherFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let fd = try holdLock(f.paths.dataDir.appendingPathComponent("update.lock"))
    defer { close(fd) }
    f.sleeps.onSleep { call in if call == 2 { flock(fd, LOCK_UN) } }
    let decisions = await f.watcher.applyPendingNow()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "swap home"], "\(decisions.map(\.line))")
    #expect(f.sleeps.all == [UpdateWatcher.applyRetry, UpdateWatcher.applyRetry])
    #expect(f.updatesLog.components(separatedBy: "skipped-locked all:").count == 3)
    #expect(f.marker("Claude Home") == "new")
  }

  /// A lock that is never released: bounded retries, then the last `skipped-locked` is returned.
  @Test func applyPendingNowGivesUpOnALockThatStaysHeld() async throws {
    let f = try await makeWatcherFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let fd = try holdLock(f.paths.dataDir.appendingPathComponent("update.lock"))
    defer { close(fd) }
    let decisions = await f.watcher.applyPendingNow()
    #expect(decisions.map(\.action) == [.skippedLocked])
    #expect(f.sleeps.all == Array(repeating: UpdateWatcher.applyRetry, count: UpdateWatcher.applyAttempts - 1))
    #expect(f.builds.isEmpty && f.marker("Claude Home") == "old")
  }

  /// A pass already running in this watcher is waited out rather than coalesced: the caller gets its own pass.
  @Test func applyPendingNowWaitsForThePassInProgress() async throws {
    var k = WatcherKnobs()
    let gate = BuildGate()
    k.buildGate = gate
    let f = try await makeWatcherFixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let watcher = f.watcher
    let first = Task { await watcher.handleOfficialChange() }
    await gate.started.wait()
    f.sleeps.onSleep { _ in
      await gate.release.open()
      _ = await first.value
    }
    let decisions = await watcher.applyPendingNow()
    await gate.release.open()
    #expect(decisionLines(await first.value) == ["skip second", "pending work", "swap home"])
    #expect(decisionLines(decisions) == ["skip second", "pending-waiting work", "skip home"], "\(decisions.map(\.line))")
    #expect(f.sleeps.all == [UpdateWatcher.applyRetry])
    #expect(f.builds.count == 2)
    #expect(!f.updatesLog.contains("coalesced"))
  }
}
