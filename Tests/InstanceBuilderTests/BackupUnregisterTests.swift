import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Every swap leaves the previous bundle in `<data>/backup/`; LaunchServices must forget it, so a bundle id, a
/// `claude://` link or Open With never resolves to that hidden copy. A failed `lsregister -u` never fails the swap.
@Suite(.serialized) struct BackupUnregisterTests {
  static let stamp = "20260921-141320"

  func unregisters(_ log: EventLog) -> [String] { log.all.filter { $0.hasPrefix("unregister") } }

  @Test func aWatcherSwapForgetsTheBackupRightAfterRegisteringTheNewApp() async throws {
    let f = try await makeWatcherFixture()
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "swap home"])
    #expect(f.log.all.suffix(2) == ["register(Claude Home.app,new)", "unregister(backup/Claude Home.app.\(Self.stamp))"])
  }

  @Test func aFailedUnregisterIsLoggedAndNeverFailsTheSwap() async throws {
    var k = WatcherKnobs()
    k.unregisterFails = true
    let f = try await makeWatcherFixture(k)
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "swap home"])
    #expect(f.marker("Claude Home") == "new")
    #expect(try await f.pending("home") == nil)
    let backup = f.paths.backupDir.appendingPathComponent("Claude Home.app.\(Self.stamp)")
    #expect(f.updatesLog.contains("[updates] lsregister -u \(backup.path) failed (home)"))
  }

  @Test func prunedBackupsAreForgottenToo() async throws {
    let f = try await makeWatcherFixture()
    for stamp in ["20260101-000000", "20260201-000000", "20260301-000000"] {
      try MiniBundle.write(
        Data("x".utf8), f.paths.backupDir.appendingPathComponent("Claude Home.app.\(stamp)/Contents/Info.plist.disabled"))
    }
    _ = await f.watcher.handleOfficialChange()
    #expect(unregisters(f.log) == [
      "unregister(backup/Claude Home.app.\(Self.stamp))", "unregister(backup/Claude Home.app.20260101-000000)",
      "unregister(backup/Claude Home.app.20260201-000000)",
    ])
    let names = try FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path).sorted()
    #expect(names == ["Claude Home.app.20260301-000000", "Claude Home.app.\(Self.stamp)"])
  }

  /// Each doomed backup is unregistered while it still exists, then deleted; legacy backups and symlinks are left.
  @Test func thePrunerForgetsEachBackupBeforeDeletingIt() async throws {
    let root = try makeTempDir()
    let names = [
      "legacy-Claude 2nd.app.20260801-000000", "Claude 2nd.app.20260902-000000", "Claude 2nd.app.20260903-000000",
      "Claude 2nd.app.20260904-000000",
    ]
    for name in names {
      try FileManager.default.createDirectory(at: root.appendingPathComponent("\(name)/Contents"), withIntermediateDirectories: true)
    }
    let outside = try makeTempDir("prune-outside")
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("Claude 2nd.app.20260901-000000"), withDestinationURL: outside)
    let events = EventLog()
    try await BackupPruner.prune(backupDir: root, appName: "Claude 2nd.app", keep: 1) { url in
      events.add("\(url.lastPathComponent),exists=\(FileManager.default.fileExists(atPath: url.path))")
    }
    #expect(events.all == ["Claude 2nd.app.20260902-000000,exists=true", "Claude 2nd.app.20260903-000000,exists=true"])
    let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    #expect(left == ["Claude 2nd.app.20260901-000000", "Claude 2nd.app.20260904-000000", "legacy-Claude 2nd.app.20260801-000000"])
    #expect(FileManager.default.fileExists(atPath: outside.path))
  }
}

/// Step 6 (`rebuild second --apply`, `rollback`) forgets the bundles it moves into the backup folder.
extension RebuildSecondTests {
  @Test func applyStillSucceedsWhenTheBackupCannotBeUnregistered() async throws {
    var k = Knobs()
    k.unregisterFails = true
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let result = try await RebuildSecond(env: f.env).apply()
    #expect(result.steps == ["check", "build", "swap", "register", "requirement", "store"])
    #expect(f.log.all.last == "unregister(backup/\(result.backup.lastPathComponent))")
    let log = try String(contentsOf: f.paths.logsDir.appendingPathComponent("updates.log"), encoding: .utf8)
    #expect(log.contains("[updates] lsregister -u \(result.backup.path) failed (rebuild second)"))
  }

  @Test func rollbackStillRestoresWhenNothingCanBeUnregistered() async throws {
    var k = Knobs()
    k.unregisterFails = true
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let rebuild = RebuildSecond(env: f.env)
    let result = try await rebuild.apply()
    try await rebuild.rollback(backup: result.backup)
    #expect(f.log.all.suffix(3) == [
      "unregister(backup/\(result.backup.lastPathComponent))", "register(Claude 2nd.app,old)",
      "unregister(failed-\(BackupUnregisterTests.stamp)/Claude 2nd.app)",
    ])
    let restored = try Data(contentsOf: f.env.liveApp.appendingPathComponent("Contents/MacOS/Claude"))
    #expect(String(decoding: restored, as: UTF8.self) == "old")
  }
}
