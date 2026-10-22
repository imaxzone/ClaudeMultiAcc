import Foundation
import Support

extension RebuildSecond {
  /// Puts a backup made by `apply` back in place: requires `not-running`; the current live app moves aside to
  /// `<data>/backup/failed-<ts>/` (its Info.plist disabled), the backup's Info.plist is re-enabled, the backup
  /// moves to the live path and is registered. A `legacy-` backup marks `second` legacy-script again (S1).
  /// LaunchServices forgets the backup's path before it moves and the set-aside app once the restored one is registered
  /// (failures only logged).
  public func rollback(backup: URL) async throws {
    let spec = env.spec
    let live = env.liveApp
    if await env.running.isRunning(bundleId: spec.bundleId, profileDir: spec.profileDir) {
      throw RebuildError.runningDuringRollback(spec.bundleId, backup: backup.path)
    }
    try validateBackup(backup, appName: live.lastPathComponent)
    await forget(backup)
    let aside = try moveLiveAside(live)
    try restore(backup, to: live, aside: aside)
    try await env.registrar.register(live)
    if let aside { await forget(aside) }
    log.info("rolled back \(live.path, privacy: .public) from \(backup.path, privacy: .public)")
    try await markRolledBack(legacy: backup.lastPathComponent.hasPrefix(BackupPlan.legacyPrefix))
  }

  /// Moves the live app into a fresh `failed-<ts>/` dir and disables its Info.plist; nil when there is none.
  private func moveLiveAside(_ live: URL) throws -> URL? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: live.path) else { return nil }
    let failedDir = env.paths.backupDir.appendingPathComponent(
      "failed-\(Timestamp.stamp(env.clock.now, timeZone: env.timeZone))", isDirectory: true)
    guard !fm.fileExists(atPath: failedDir.path) else { throw RebuildError.backupInvalid("\(failedDir.path) exists") }
    try fm.createDirectory(at: failedDir, withIntermediateDirectories: true)
    let moved = failedDir.appendingPathComponent(live.lastPathComponent, isDirectory: true)
    try env.mover.move(live, moved)
    _ = attemptUndo("disable plist of \(moved.path)", log: logError) { try env.mover.disablePlist(in: moved) }
    return moved
  }

  /// Enables and moves the backup to `live`; on failure disables the backup again and puts `aside` back.
  private func restore(_ backup: URL, to live: URL, aside: URL?) throws {
    var enabled = false
    do {
      try env.mover.enablePlist(in: backup)
      enabled = true
      try env.mover.move(backup, live)
    } catch {
      if enabled {
        _ = attemptUndo("disable backup plist", log: logError) { try env.mover.disablePlist(in: backup) }
      }
      guard let aside else { throw error }
      let enable = attemptUndo("enable plist of \(aside.path)", log: logError) { try env.mover.enablePlist(in: aside) }
      let back = attemptUndo("move \(aside.path) back", log: logError) { try env.mover.move(aside, live) }
      if enable != nil || back != nil {
        throw RebuildError.compensationFailed(original: String(describing: error), leftAt: back == nil ? live.path : aside.path)
      }
      throw error
    }
  }

  /// `legacy-` backup → `builtBy: "legacy-script"`, no pending build; any other backup keeps `builtBy`.
  private func markRolledBack(legacy: Bool) async throws {
    guard legacy else { return }
    let store = InstanceStore(paths: env.paths)
    do {
      guard let second = try await store.loadOrSeed().first(where: { $0.slug == env.spec.slug }) else { return }
      _ = try await store.upsert(second.withBuild(builtBy: "legacy-script", pendingBuild: nil))
    } catch {
      logError("restored, but instances.json was not updated: \(error)")
      throw RebuildError.afterRollback(message: String(describing: error))
    }
  }

  private func logError(_ message: String) {
    log.error("\(message, privacy: .public)")
  }

  /// Only real directories directly inside `<data>/backup/`, named `[legacy-]<app>.<stamp>`, with a disabled
  /// Info.plist.
  private func validateBackup(_ backup: URL, appName: String) throws {
    let parent = backup.standardizedFileURL.deletingLastPathComponent().path
    var info = stat()
    let isRealDir = lstat(backup.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    let name = backup.lastPathComponent
    let named = name.hasPrefix(appName + ".") || name.hasPrefix(BackupPlan.legacyPrefix + appName + ".")
    let disabled = backup.appendingPathComponent("Contents/\(BundleSwapper.disabledPlist)")
    guard parent == env.paths.backupDir.standardizedFileURL.path, isRealDir, named,
          FileManager.default.fileExists(atPath: disabled.path)
    else { throw RebuildError.backupInvalid(backup.path) }
  }
}
