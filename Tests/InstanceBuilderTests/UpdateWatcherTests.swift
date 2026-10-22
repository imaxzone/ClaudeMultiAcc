import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

@Suite(.serialized) struct UpdateWatcherTests {
  typealias Knobs = WatcherKnobs
  typealias Fixture = WatcherFixture

  private func writeApp(_ app: URL, version: String, marker: String) throws {
    try writeWatcherApp(app, version: version, marker: marker)
  }

  private func fixture(_ k: Knobs = Knobs(), _ name: String = #function) async throws -> Fixture {
    try await makeWatcherFixture(k, name)
  }

  private func lines(_ decisions: [UpdateDecision]) -> [String] { decisionLines(decisions) }

  private func marker(_ app: String, _ root: URL) -> String { appMarker(app, root) }

  @Test func oneSwapOnePendingOneSkipInListOrder() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions) == ["skip second", "pending work", "swap home"])
    #expect(decisions[0].line == "skip second: builtBy=legacy-script")
    #expect(marker("Claude Home", f.root) == "new" && marker("Claude Work", f.root) == "old")
    #expect(marker("Claude 2nd", f.root) == "old")
    #expect(f.log.all == [
      "build(stagingOnly,certificate,work)", "build(stagingOnly,certificate,home)", "register(Claude Home.app,new)",
      "unregister(backup/Claude Home.app.20260921-141320)",
    ])
    let stored = try await InstanceStore(paths: f.paths).load()
    let work = try #require(stored.first { $0.slug.raw == "work" })
    let pending = try #require(work.pendingBuild)
    #expect(pending.hasSuffix(".noindex/Claude Work.app") && FileManager.default.fileExists(atPath: pending))
    #expect(stored.first { $0.slug.raw == "home" }?.pendingBuild == nil)
    #expect(stored.map(\.slug.raw) == ["main", "second", "work", "alt", "home"])
    let logText = try String(contentsOf: f.paths.logsDir.appendingPathComponent("updates.log"), encoding: .utf8)
    #expect(logText.contains("skip second: builtBy=legacy-script"))
    #expect(logText.contains("pending work:") && logText.contains("swap home: 1.0.0 → 2.0.0"))
  }

  /// R1: a swap writes no Finder custom icon (the new bundle carries its badge in `electron.icns`) and the decision
  /// mentions none.
  @Test func aSwapWritesNoCustomIcon() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions) == ["skip second", "pending work", "swap home"])
    #expect(!decisions[2].detail.contains("icon"))
    let home = f.root.appendingPathComponent("Applications/Claude Home.app")
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(CustomIconCheck.iconFile).path))
  }

  /// A downloaded update waiting for the official app to quit does not hold the clones back.
  @Test func pendingVendorUpdateDoesNotRetry() async throws {
    var k = Knobs()
    k.vendor = .waitingForQuit
    let f = try await fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions) == ["skip second", "pending work", "swap home"], "\(decisions.map(\.line))")
  }

  @Test(arguments: ["auto-off", "shipit", "not-newer", "no-identity", "unverified", "dry"])
  func decisionTable(row: String) async throws {
    var k = Knobs()
    switch row {
    case "auto-off": k.autoRebuild = false
    case "shipit": k.vendor = .installing
    case "not-newer": k.cloneVersion = "2.0.0"
    case "no-identity": k.identity = false
    case "unverified": k.verified = false
    default: break
    }
    let f = try await fixture(k, "table-\(row)")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let decisions = row == "dry" ? await f.watcher.evaluate(apply: false) : await f.watcher.handleOfficialChange()
    let expected: [String: [String]] = [
      "auto-off": ["skip second", "skip work", "skip home"],
      "shipit": ["skip second", "retry work", "retry home"],
      "not-newer": ["skip second", "skip work", "skip home"],
      "no-identity": ["skip second", "needs-identity work", "needs-identity home"],
      "unverified": ["skip second", "fail work", "fail home"],
      "dry": ["skip second", "would-rebuild work", "would-rebuild home"],
    ]
    #expect(lines(decisions) == expected[row], "\(decisions.map(\.line))")
    #expect(marker("Claude Home", f.root) == "old")
    #expect(!f.log.all.contains { $0.hasPrefix("register") })
    if row != "unverified" { #expect(f.log.all.isEmpty) }
  }

  /// The menu re-reads versions after every applying pass, even one that wrote nothing (auto-rebuild off, ShipIt…).
  @Test func everyApplyingPassIsAnnounced() async throws {
    var k = Knobs()
    k.autoRebuild = false
    let f = try await fixture(k, "announce")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let count = Mutex(0)
    await f.watcher.onPassFinished { count.withLock { $0 += 1 } }
    _ = await f.watcher.evaluate(apply: false)
    #expect(count.withLock { $0 } == 0)
    _ = await f.watcher.handleOfficialChange()
    #expect(count.withLock { $0 } == 1)
    #expect(await f.watcher.waitUntilIdle(timeout: .milliseconds(50)))
  }

  /// «Обновить» in the menu is a manual pass: `updates.autoRebuild` only holds back the automatic ones.
  @Test func aManualPassBuildsEvenWithAutoRebuildOff() async throws {
    var k = Knobs()
    k.autoRebuild = false
    let f = try await fixture(k, "manual-auto-off")
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(lines(await f.watcher.handleOfficialChange()) == ["skip second", "skip work", "skip home"])
    let decisions = await f.watcher.applyPendingNow(manual: true)
    #expect(lines(decisions) == ["skip second", "pending work", "swap home"], "\(decisions.map(\.line))")
  }

  /// A launcher holding `<profile>/.clone.lock` means "running" even when no process is visible.
  @Test func aHeldCloneLockKeepsTheBuildPending() async throws {
    var k = Knobs()
    k.running = []
    let f = try await fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let lock = f.root.appendingPathComponent("profiles/home/.clone.lock")
    try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lock.path, contents: nil)
    let fd = open(lock.path, O_RDWR)
    #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
    defer { close(fd) }
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions) == ["skip second", "swap work", "pending home"])
  }

  private func builds(_ f: Fixture) -> [String] { f.builds }

  private func pending(_ f: Fixture, _ slug: String) async throws -> String? { try await f.pending(slug) }

  /// FSEvent, hourly and retry passes (or the app and the LaunchAgent) firing together build each clone once.
  @Test func concurrentPassesBuildEachCloneOnce() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    async let first = f.watcher.handleOfficialChange()
    async let second = f.watcher.handleOfficialChange()
    _ = await (first, second)
    #expect(builds(f) == ["build(stagingOnly,certificate,work)", "build(stagingOnly,certificate,home)"])
    #expect(f.log.all.filter { $0.hasPrefix("register") } == ["register(Claude Home.app,new)"])
  }

  /// Another process (the LaunchAgent's `cmacc update check`) holds `<data>/update.lock`: skip, touch nothing.
  @Test func aHeldUpdateLockSkipsThePass() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let lock = f.paths.dataDir.appendingPathComponent("update.lock")
    FileManager.default.createFile(atPath: lock.path, contents: nil)
    let fd = open(lock.path, O_RDWR)
    #expect(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
    defer { close(fd) }
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisions.map(\.action) == [.skippedLocked])
    #expect(decisions.first?.line == "skipped-locked all: another pass holds update.lock")
    #expect(f.log.all.isEmpty)
    #expect(marker("Claude Home", f.root) == "old")
  }

  @Test func aValidPendingBuildIsSwappedWithoutRebuildingOnceIdle() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = await f.watcher.handleOfficialChange()
    f.running.set([])
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions).prefix(2) == ["skip second", "swap work"])
    #expect(builds(f).count == 2)
    #expect(f.log.all.suffix(2) == ["register(Claude Work.app,new)", "unregister(backup/Claude Work.app.20260921-141320)"])
    #expect(marker("Claude Work", f.root) == "new")
    #expect(try await pending(f, "work") == nil)
    #expect(try StagingArea(paths: f.paths).builds(slug: testSlug("work")).isEmpty)
  }

  @Test func aValidPendingBuildWaitsWhileTheCloneRuns() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = await f.watcher.handleOfficialChange()
    let staged = try await pending(f, "work")
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions).prefix(2) == ["skip second", "pending-waiting work"])
    #expect(builds(f).count == 2)
    #expect(try await pending(f, "work") == staged)
    #expect(marker("Claude Work", f.root) == "old")
  }

  /// A pending build for an older official version, or one whose dir vanished, is discarded and rebuilt.
  @Test(arguments: ["version", "missing"])
  func aStalePendingBuildIsDiscardedAndRebuilt(reason: String) async throws {
    let f = try await fixture(Knobs(), "stale-\(reason)")
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = await f.watcher.handleOfficialChange()
    let old = try #require(try await pending(f, "work"))
    if reason == "version" {
      try writeApp(f.root.appendingPathComponent("Applications/Claude.app"), version: "2.1.0", marker: "official")
    } else {
      try FileManager.default.removeItem(at: URL(fileURLWithPath: old).deletingLastPathComponent())
    }
    let decisions = await f.watcher.handleOfficialChange()
    #expect(lines(decisions).prefix(2) == ["skip second", "pending work"])
    #expect(builds(f).filter { $0.hasSuffix(",work)") }.count == 2)
    let fresh = try #require(try await pending(f, "work"))
    #expect(fresh != old && FileManager.default.fileExists(atPath: fresh))
    #expect(!FileManager.default.fileExists(atPath: old))
    #expect(try StagingArea(paths: f.paths).builds(slug: testSlug("work")).count == 1)
  }

  @Test func backupsArePrunedToTwoPerClone() async throws {
    let f = try await fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for stamp in ["20260101-000000", "20260201-000000", "20260301-000000"] {
      try MiniBundle.write(Data("x".utf8), f.paths.backupDir.appendingPathComponent("Claude Home.app.\(stamp)/Contents/Info.plist.disabled"))
    }
    try MiniBundle.write(Data("x".utf8), f.paths.backupDir.appendingPathComponent("Claude Work.app.20250101-000000/Contents/x"))
    _ = await f.watcher.handleOfficialChange()
    let names = try FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path).sorted()
    #expect(names == ["Claude Home.app.20260301-000000", "Claude Home.app.20260921-141320", "Claude Work.app.20250101-000000"])
  }
}
