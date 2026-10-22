import Foundation
import os
import Support

/// A verified edit build in place and recorded, with where the previous bundle is now.
struct PlacedEdit: Sendable {
  let instance: Instance
  /// A rename's previous bundle (set aside for a letter-case rename); it goes to the Trash next.
  let retired: URL?
  /// The backup of an in-place swap; LaunchServices forgets it next.
  let backup: URL?
}

/// Putting a verified edit build in place: every step until `instances.json` is written is undone on failure (never
/// silently: a failed undo says what is left where).
extension EditInstance {
  func install(_ plan: EditPlan, staged: URL) async throws -> PlacedEdit {
    switch plan.kind {
    case .inPlace:
      let (instance, backup) = try await swapInPlace(plan, staged: staged)
      return PlacedEdit(instance: instance, retired: nil, backup: backup)
    case .rename, .caseRename:
      let (instance, retired) = try await moveRenamed(plan, staged: staged)
      return PlacedEdit(instance: instance, retired: retired, backup: nil)
    }
  }

  /// The previous bundle goes to the backup folder (kept like an update's backup) and comes back on failure. It must
  /// still be the app checked before the build. Returns the new entry and the backup.
  private func swapInPlace(_ plan: EditPlan, staged: URL) async throws -> (Instance, URL) {
    let backup: URL
    do {
      guard let identity = plan.checkedApp.identity else { throw SwapError.liveMissing(plan.oldApp.path) }
      backup = try await effects.swapper.swap(live: plan.oldApp, staged: staged, expectedLive: identity)
    } catch SwapError.liveChanged {
      throw plan.appChanged(home: paths.home)
    } catch {
      if case .compensationFailed(_, let leftAt)? = error as? SwapError {
        throw EditInstanceError.compensationFailed(step: "swap", leftAt: leftAt)
      }
      throw EditInstanceError.installFailed(step: "swap", message: String(describing: error))
    }
    let instance = try await recordPlaced(plan, at: plan.oldApp) { step in
      do {
        try effects.mover.move(plan.oldApp, staged)
        try effects.mover.enablePlist(in: backup)
        try effects.mover.move(backup, plan.oldApp)
      } catch {
        throw EditInstanceError.compensationFailed(step: step, leftAt: backup.path)
      }
    }
    return (instance, backup)
  }

  /// The build moves to `<new name>.app`; the old bundle stays (set aside under a hidden name for a letter-case
  /// rename) until the new one is registered and recorded.
  private func moveRenamed(_ plan: EditPlan, staged: URL) async throws -> (Instance, URL?) {
    let aside = plan.kind == .caseRename ? try setAside(plan) : nil
    guard !FileManager.default.fileExists(atPath: plan.newApp.path) else {
      try restore(aside, plan, step: "move")
      throw EditInstanceError.targetExists(plan.newApp.path)
    }
    do {
      try effects.mover.move(staged, plan.newApp)
    } catch {
      try restore(aside, plan, step: "move")
      throw EditInstanceError.installFailed(step: "move", message: String(describing: error))
    }
    let instance = try await recordPlaced(plan, at: plan.newApp) { step in
      do {
        try effects.mover.move(plan.newApp, staged)
      } catch {
        throw EditInstanceError.compensationFailed(step: step, leftAt: plan.newApp.path)
      }
      try restore(aside, plan, step: step)
    }
    return (instance, aside ?? plan.oldApp)
  }

  private func setAside(_ plan: EditPlan) throws -> URL {
    guard plan.checkedApp.identity != nil, plan.checkedApp.state() == .unchanged else {
      throw plan.appChanged(home: paths.home)
    }
    let name = ".\(plan.oldApp.lastPathComponent).replaced-\(UUID().uuidString.prefix(8))"
    let aside = plan.oldApp.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
    do {
      try effects.mover.move(plan.oldApp, aside)
    } catch {
      throw EditInstanceError.installFailed(step: "set-aside", message: String(describing: error))
    }
    return aside
  }

  private func restore(_ aside: URL?, _ plan: EditPlan, step: String) throws {
    guard let aside else { return }
    do {
      try effects.mover.move(aside, plan.oldApp)
    } catch {
      throw EditInstanceError.compensationFailed(step: step, leftAt: aside.path)
    }
  }

  /// Registers the placed bundle and writes `instances.json`; on failure runs `undo` (which gets the failed step),
  /// re-registers the previous bundle and throws `.installFailed`.
  private func recordPlaced(
    _ plan: EditPlan, at app: URL, undo: (String) throws -> Void
  ) async throws -> Instance {
    var step = "register"
    do {
      try await effects.registrar.register(app)
      step = "store"
      _ = try await effects.store.upsert(plan.edited)
      return plan.edited
    } catch {
      let message = String(describing: error)
      log.error("\(step, privacy: .public) failed for \(app.path, privacy: .public): \(message, privacy: .public); undoing")
      try undo(step)
      do {
        try await effects.registrar.register(plan.oldApp)
      } catch {
        log.error("re-registering \(plan.oldApp.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      }
      throw EditInstanceError.installFailed(step: step, message: message)
    }
  }

  // MARK: After the install

  /// Retires the previous bundle of a rename or unregisters the backup of a swap, and tidies staging and backups;
  /// returns warnings in the UI language.
  func finish(_ plan: EditPlan, placed: PlacedEdit) async -> [String] {
    var warnings: [String] = []
    if let retired = placed.retired, let warning = await retire(retired, plan: plan) { warnings.append(warning) }
    if let backup = placed.backup { await forget(backup) }
    do {
      _ = try StagingArea(paths: paths).discard(slug: plan.instance.slug)
      if plan.kind == .inPlace {
        // Pruned backups leave LaunchServices first, like the update watcher's.
        _ = try await BackupPruner.prune(
          backupDir: paths.backupDir, appName: plan.oldApp.lastPathComponent, keep: UpdateWatcher.backupsPerClone,
          unregister: { [self] url in await forget(url) })
      }
    } catch {
      log.error("cleanup \(plan.instance.slug.raw, privacy: .public): \(String(describing: error), privacy: .public)")
    }
    return warnings
  }

  /// The backup still carries the clone's bundle id: unregistered, macOS no longer offers or opens that old copy. A
  /// failure is only logged — the edit stands.
  private func forget(_ backup: URL) async {
    do {
      try await effects.unregistrar.unregister(backup)
    } catch {
      log.error("unregister \(backup.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// LaunchServices forgets the old bundle (a letter-case rename keeps its record, now the new app's), its
  /// Info.plist is disabled so nothing launches it by bundle id, and it goes to the Trash — only while it is still the
  /// app checked before the build (a set-aside copy keeps its device and inode).
  private func retire(_ old: URL, plan: EditPlan) async -> String? {
    guard let checked = plan.checkedApp.identity, FileIdentity.of(old) == checked else {
      log.error("not retiring \(old.path, privacy: .public): changed since the check")
      return BuilderText.format("edit.retire-changed", plan.instance.name, old.path)
    }
    if plan.kind == .rename {
      do {
        try await effects.unregistrar.unregister(old)
      } catch {
        log.error("unregister \(old.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      }
    }
    do {
      try effects.mover.disablePlist(in: old)
    } catch {
      log.error("cannot disable \(old.path, privacy: .public): \(String(describing: error), privacy: .public)")
    }
    do {
      try await effects.trash.trash(old)
      return nil
    } catch {
      log.error("trash \(old.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      return BuilderText.format("edit.retire-failed", plan.instance.name, old.path)
    }
  }
}
