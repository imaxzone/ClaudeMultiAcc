import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// The pre-step-6 backup of the legacy `Claude 2nd` is the only copy of the old build: never pruned.
@Suite struct LegacyBackupTests {
  @Test func prunerNeverRemovesLegacyBackups() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let names = [
      "legacy-Claude 2nd.app.20260901-000000", "Claude 2nd.app.20260902-000000", "Claude 2nd.app.20260903-000000",
      "Claude 2nd.app.20260904-000000",
    ]
    for name in names {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let removed = try BackupPruner.prune(backupDir: root, appName: "Claude 2nd.app", keep: 1)
    #expect(removed.map(\.lastPathComponent) == ["Claude 2nd.app.20260902-000000", "Claude 2nd.app.20260903-000000"])
    // Even a caller that names the legacy prefix as the app never gets it pruned.
    #expect(try BackupPruner.prune(backupDir: root, appName: "legacy-Claude 2nd.app", keep: 0).isEmpty)
    let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    #expect(left == ["Claude 2nd.app.20260904-000000", "legacy-Claude 2nd.app.20260901-000000"])
  }

  @Test func swapperNamesTheBackupWithThePrefix() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Apps/Claude 2nd.app")
    let staged = root.appendingPathComponent("Apps/staged.app")
    try MiniBundle.write(Data("<plist/>".utf8), live.appendingPathComponent("Contents/Info.plist"))
    try MiniBundle.write(Data("<plist/>".utf8), staged.appendingPathComponent("Contents/Info.plist"))
    let backup = try BundleSwapper.swap(
      live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
      now: Date(timeIntervalSince1970: 1_790_000_000), timeZone: .gmt, backupPrefix: "legacy-")
    #expect(backup.lastPathComponent == "legacy-Claude 2nd.app.20260921-141320")
  }

  /// Every message that stops a half-finished rebuild names the exact command that finishes it.
  @Test func stopMessagesSayHowToFinish() {
    let running = RebuildError.targetRunning("com.anthropic.claudefordesktop2").description
    #expect(running.contains("cmacc instance rebuild second --apply"))
    let rollback = RebuildError.runningDuringRollback("com.anthropic.claudefordesktop2", backup: "/b/x").description
    #expect(rollback.contains("cmacc instance rollback second /b/x"))
    let after = RebuildError.afterSwap(step: "register", backup: "/b/x", message: "running").description
    #expect(after.contains("cmacc instance rollback second /b/x"))
    #expect(after.contains("cmacc instance rebuild second --apply"))
    #expect(RebuildError.afterSwap(step: "register", backup: "/b/x", message: "m").userMessage.contains("cmacc instance rollback second"))
  }
}
