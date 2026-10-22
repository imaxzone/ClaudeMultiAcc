import AppKit
import Foundation
import os
import Support

/// `NSRunningApplication.terminate()` on every running app with the bundle id: a polite quit, never a force kill. Only
/// a clone's id is accepted (`ClonePathPolicy.isCloneBundleId`): a registry entry naming Xcode, Finder, the official
/// Claude or ClaudeMultiAcc quits nothing.
struct WorkspaceQuitter: AppQuitting {
  func requestQuit(bundleId: String) async -> Bool {
    guard Self.mayQuit(bundleId: bundleId) else {
      AppLog.logger("instances").error("refused to quit \(bundleId, privacy: .public): not a clone's bundle id")
      return false
    }
    return await MainActor.run {
      NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).map { $0.terminate() }.contains(true)
    }
  }

  static func mayQuit(bundleId: String) -> Bool { ClonePathPolicy.isCloneBundleId(bundleId) }
}

/// `NSWorkspace.openApplication(at:configuration:)` in the background, as Finder opens an app (through its launcher).
struct WorkspaceOpener: AppOpening {
  func open(app: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
  }
}

extension CloneRestarter {
  /// The real machine: NSRunningApplication quit requests, NSWorkspace reopening, NSRunningApplication/lsappinfo/lock
  /// running checks and `~/Library/Logs/ClaudeMultiAcc/updates.log`.
  public static func live(paths: Paths, runner: ProcessRunning, applier: any PendingApplying) -> CloneRestarter {
    CloneRestarter(
      store: InstanceStore(paths: paths), running: RunningCheck(runner: runner), quitter: WorkspaceQuitter(),
      opener: WorkspaceOpener(), applier: applier,
      log: RedactingFileLog(url: paths.logsDir.appendingPathComponent("updates.log")))
  }
}
