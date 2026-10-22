import Foundation
import Support

extension UpdateWatcher {
  static let backupsPerClone = 2

  /// A clone's `pendingBuild`: none, a verified build for the current official version, or stale.
  enum PendingState: Equatable {
    case none
    case valid(URL)
    case stale(String)
  }

  /// The decision table for one clone, in order: builtBy, auto-rebuild, ShipIt installing, forward-only version, a valid
  /// pending build (swap when idle, else keep waiting), identity, staging build (discarding stale and superseded
  /// builds first), then swap when idle or keep the build pending.
  func decide(_ instance: Instance, official: String?, autoRebuild: Bool, apply: Bool) async -> UpdateDecision {
    let slug = instance.slug.raw
    guard instance.builtBy == "cmacc" else {
      return UpdateDecision(slug: slug, action: .skip, detail: "builtBy=\(instance.builtBy ?? "unknown")")
    }
    guard autoRebuild else { return UpdateDecision(slug: slug, action: .skip, detail: UpdateDecision.autoRebuildOff) }
    if await vendorShipIt.state() == .installing {
      return UpdateDecision(slug: slug, action: .retry, detail: "vendor ShipIt installing (retry in 10 min)")
    }
    guard let official, let clone = instance.installedVersion else {
      return UpdateDecision(slug: slug, action: .skip, detail: "version unreadable (official \(official ?? "?"))")
    }
    guard VersionCompare.isNewer(official, than: clone) else {
      return UpdateDecision(slug: slug, action: .skip, detail: "not newer (clone \(clone), official \(official))")
    }
    var note = ""
    switch pendingState(instance, official: official) {
    case .valid(let staged):
      guard apply else { return UpdateDecision(slug: slug, action: .wouldRebuild, detail: "\(clone) → \(official): swap pending build") }
      return await swapPending(instance, staged: staged, from: clone, to: official)
    case .stale(let why): note = "discarded stale pending build (\(why)); "
    case .none: break
    }
    guard let identity = await identity() else {
      return UpdateDecision(slug: slug, action: .needsIdentity, detail: "no permanent signing identity (\(SigningSetup.hint))")
    }
    guard apply else { return UpdateDecision(slug: slug, action: .wouldRebuild, detail: "\(clone) → \(official)") }
    return await rebuild(instance, identity: identity, from: clone, to: official, note: note)
  }

  func pendingState(_ instance: Instance, official: String) -> PendingState {
    guard let path = instance.pendingBuild else { return .none }
    let app = URL(fileURLWithPath: path, isDirectory: true)
    var isDir: ObjCBool = false
    guard StagingArea(paths: paths).contains(app), FileManager.default.fileExists(atPath: app.path, isDirectory: &isDir),
          isDir.boolValue
    else { return .stale("missing") }
    let reportURL = app.deletingLastPathComponent().appendingPathComponent("build-report.json")
    guard let data = try? Data(contentsOf: reportURL), let report = try? JSONCoding.decoder.decode(BuildReport.self, from: data)
    else { return .stale("no readable build-report.json") }
    guard report.verified, report.slug == instance.slug.raw, report.identityKind != SigningIdentity.adhoc.kind,
          URL(fileURLWithPath: report.stagedPath).standardizedFileURL == app.standardizedFileURL
    else { return .stale("not a verified build of \(instance.slug.raw)") }
    guard report.sourceVersion == official else { return .stale("built from \(report.sourceVersion)") }
    return .valid(app)
  }

  private func swapPending(_ instance: Instance, staged: URL, from clone: String, to official: String) async -> UpdateDecision {
    let slug = instance.slug.raw
    do {
      let spec = try CloneSpec.from(instance: instance)
      guard await isIdle(instance, spec: spec) else {
        return UpdateDecision(slug: slug, action: .pendingWaiting, detail: "running; \(official) build waits at \(staged.path)")
      }
      let backup = try await swapIn(instance, staged: staged)
      return UpdateDecision(
        slug: slug, action: .swap, detail: "\(clone) → \(official) from pending build (backup \(backup.path))")
    } catch {
      return UpdateDecision(slug: slug, action: .fail, detail: String(describing: error))
    }
  }

  private func rebuild(
    _ instance: Instance, identity: SigningIdentity, from clone: String, to official: String, note: String
  ) async -> UpdateDecision {
    let slug = instance.slug.raw
    do {
      let spec = try CloneSpec.from(instance: instance)
      _ = try clonePolicy.checkApp(instance)
      _ = try StagingArea(paths: paths).discard(slug: instance.slug)
      let report = try await pipeline.build(spec: spec, source: officialApp, identity: identity, intent: .stagingOnly)
      guard report.verified else {
        return UpdateDecision(slug: slug, action: .fail, detail: "\(note)build not verified: \(report.failure?.message ?? "?")")
      }
      let staged = URL(fileURLWithPath: report.stagedPath, isDirectory: true)
      guard await isIdle(instance, spec: spec) else {
        _ = try await store.upsert(instance.withBuild(builtBy: instance.builtBy, pendingBuild: report.stagedPath))
        return UpdateDecision(slug: slug, action: .pending, detail: "\(note)running; \(clone) → \(official) staged at \(report.stagedPath)")
      }
      let backup = try await swapIn(instance, staged: staged)
      return UpdateDecision(slug: slug, action: .swap, detail: "\(note)\(clone) → \(official) (backup \(backup.path))")
    } catch {
      return UpdateDecision(slug: slug, action: .fail, detail: "\(note)\(String(describing: error))")
    }
  }

  /// The positive path rules for the clone's app (`ClonePathPolicy`), checked before the build and again before the swap.
  var clonePolicy: ClonePathPolicy { ClonePathPolicy(home: paths.home, officialApp: officialApp) }

  /// Swap, register, make LaunchServices forget the backup, clear `pendingBuild`, drop the emptied staging dirs and keep
  /// two backups of this clone (each pruned one unregistered first); returns the backup. A failed `lsregister -u` is only
  /// logged. The app is checked by `clonePolicy` now and compared again (device and inode) right before the rename. The
  /// new bundle already carries its badge in `electron.icns` (R1), so nothing is written into it.
  private func swapIn(_ instance: Instance, staged: URL) async throws -> URL {
    let checked = try clonePolicy.checkApp(instance)
    let live = checked.url
    guard let identity = checked.identity else { throw SwapError.liveMissing(live.path) }
    let backup = try BundleSwapper.swap(
      live: live, staged: staged, backupDir: paths.backupDir, now: clock.now, timeZone: timeZone, expectedLive: identity)
    try await registrar.register(live)
    let slug = instance.slug.raw
    await registrar.unregisterLogged(backup, context: slug, log: log)
    _ = try await store.upsert(instance.withBuild(builtBy: "cmacc", pendingBuild: nil))
    do {
      _ = try StagingArea(paths: paths).discard(slug: instance.slug)
      try await BackupPruner.prune(
        backupDir: paths.backupDir, appName: live.lastPathComponent, keep: Self.backupsPerClone
      ) { [registrar, log] old in
        _ = await registrar.unregisterLogged(old, context: "\(slug) prune", log: log)
      }
    } catch {
      await log.write("cleanup \(instance.slug.raw): \(error)", category: "updates")
    }
    return backup
  }

  /// Not running (NSRunningApplication/lsappinfo via `running`) and the launcher's profile lock is free.
  func isIdle(_ instance: Instance, spec: CloneSpec) async -> Bool {
    if await running.isRunning(bundleId: spec.bundleId, profileDir: spec.profileDir) { return false }
    return !RunningCheck.isLockHeld(spec.profileDir.appendingPathComponent(".clone.lock"))
  }
}
