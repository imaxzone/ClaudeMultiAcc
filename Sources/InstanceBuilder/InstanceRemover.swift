import Foundation
import Support

/// Moves an item to the Trash (never deletes it); returns where it landed when the system says.
public protocol Trashing: Sendable {
  func trash(_ url: URL) throws -> URL?
}

/// Bytes on disk under a path; 0 when it is missing. Symlinks are never followed.
public protocol SizeMeasuring: Sendable {
  func size(of url: URL) async -> Int64
}

/// Removes an app from the LaunchServices database.
public protocol AppUnregistering: Sendable {
  func unregister(_ app: URL) async throws
}

/// One try at `<data>/update.lock`, which every applying update pass holds.
public enum RemovalLockAttempt: Sendable {
  case acquired(release: @Sendable () -> Void)
  case busy
  case failed(String)
}

public protocol RemovalLocking: Sendable {
  func tryAcquire() -> RemovalLockAttempt
}

/// What the «Удалить «…»…» dialog needs: the target, its sizes and the removal itself.
public protocol InstanceRemoving: Sendable {
  func target(slug: String) async throws -> RemovalTarget
  /// Bytes `.appOnly` moves: the app and its backups and staging builds.
  func appOnlySize(of target: RemovalTarget) async -> Int64
  /// Bytes of the profile, which `.everything` moves too.
  func profileSize(of target: RemovalTarget) async -> Int64
  func remove(slug: String, mode: RemovalMode) async -> RemovalReport
}

/// Removes one clone: quits it politely, moves its app (and its old copies, and in `.everything` its profile) to the
/// Trash, unregisters it from LaunchServices and drops its `instances.json` record — all under `update.lock`, so no
/// update pass swaps a build in meanwhile. Official and CLI-only instances are refused, and so is any entry whose app
/// or profile `ClonePathPolicy` does not accept. Each item is compared with what was checked right before it moves.
/// If the app does not quit, cannot be moved or was swapped, nothing changes; later failures are reported item by item.
public struct InstanceRemover: InstanceRemoving {
  static let pollInterval: Duration = .milliseconds(500)
  static let quitTimeout: Duration = .seconds(30)
  static let lockTimeout: Duration = .seconds(30)
  static let logCategory = "instances"

  let paths: Paths
  let store: InstanceStore
  let running: any RunningChecking
  let quitter: any AppQuitting
  let trasher: any Trashing
  let unregistrar: any AppUnregistering
  let sizer: any SizeMeasuring
  let lock: any RemovalLocking
  let log: RedactingFileLog
  let policy: ClonePathPolicy
  let sleep: @Sendable (Duration) async -> Void

  /// `systemApplications` is `/Applications` except in tests.
  public init(
    paths: Paths, store: InstanceStore, running: any RunningChecking, quitter: any AppQuitting, trasher: any Trashing,
    unregistrar: any AppUnregistering, sizer: any SizeMeasuring, lock: any RemovalLocking, log: RedactingFileLog,
    officialApp: URL = ClonePathPolicy.vendorApp, systemApplications: URL = ApplicationsMover.systemApplications,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.paths = paths
    self.store = store
    self.running = running
    self.quitter = quitter
    self.trasher = trasher
    self.unregistrar = unregistrar
    self.sizer = sizer
    self.lock = lock
    self.log = log
    policy = ClonePathPolicy(home: paths.home, officialApp: officialApp, systemApplications: systemApplications)
    self.sleep = sleep
  }

  public func target(slug: String) async throws -> RemovalTarget {
    let instances: [Instance]
    do {
      instances = try await store.load()
    } catch {
      throw RemovalError.storeUnreadable(String(describing: error))
    }
    guard let instance = instances.first(where: { $0.slug.raw == slug }) else { throw RemovalError.notFound(slug) }
    guard instance.kind == .clone else { throw RemovalError.notAClone(name: instance.name, kind: instance.kind) }
    guard instance.appPath != nil, let bundleId = instance.bundleId else {
      throw RemovalError.incomplete(instance.name)
    }
    let app: CheckedPath
    let profile: CheckedPath?
    do {
      app = try policy.checkApp(instance, others: instances)
      profile = try policy.checkProfile(instance, others: instances)
    } catch let refusal as ClonePathRefusal {
      await note(slug, "refused: \(refusal)")
      throw RemovalError.unsafePath(refusal)
    }
    // The policy only accepts the standard profile of the slug: adding the same name again finds it.
    let reusable = profile != nil && NewInstanceRequest.slug(fromName: Self.shortName(instance.name)) == slug
    let backups = Self.backups(of: app.url.lastPathComponent, in: paths.backupDir)
    let staging = ((try? StagingArea(paths: paths).builds(slug: instance.slug)) ?? []).filter(Self.isRealDirectory)
    return RemovalTarget(
      slug: instance.slug, name: instance.name, bundleId: bundleId, app: app.url, profileDir: profile?.url,
      backups: backups, stagingBuilds: staging, profileReusable: reusable,
      checked: [app] + (profile.map { [$0] } ?? []) + (backups + staging).map(CheckedPath.now))
  }

  public func appOnlySize(of target: RemovalTarget) async -> Int64 {
    var total: Int64 = 0
    for item in target.items(.appOnly) { total += await sizer.size(of: item.url) }
    return total
  }

  public func profileSize(of target: RemovalTarget) async -> Int64 {
    guard let profile = target.profileDir else { return 0 }
    return await sizer.size(of: profile)
  }

  public func remove(slug: String, mode: RemovalMode) async -> RemovalReport {
    let target: RemovalTarget
    do {
      target = try await self.target(slug: slug)
    } catch {
      await note(slug, "refused: \(error)")
      return .refused(slug: slug, name: slug, (error as? RemovalError)?.userMessage ?? UserMessage.text(for: error))
    }
    await note(slug, "start (\(mode.rawValue))")
    let release: @Sendable () -> Void
    switch await acquireLock(slug) {
    case .acquired(let releaseLock): release = releaseLock
    case .busy:
      return stop(target, BuilderText.format("remove.busy", target.name))
    case .failed:
      return stop(target, BuilderText.format("remove.lock-failed", target.name))
    }
    defer { release() }
    // Read again under the lock: an update pass that ran while we waited may have added a backup or staging build.
    let current: RemovalTarget
    do {
      current = try await self.target(slug: slug)
    } catch {
      await note(slug, "refused under the lock: \(error)")
      return stop(target, (error as? RemovalError)?.userMessage ?? UserMessage.text(for: error))
    }
    guard await quitIfRunning(current) else {
      let seconds = Int(Self.quitTimeout.components.seconds)
      return stop(current, BuilderText.format("remove.still-running", current.name, seconds))
    }
    return await trashAndForget(current, mode: mode)
  }

  private func stop(_ target: RemovalTarget, _ problem: String) -> RemovalReport {
    .refused(slug: target.slug.raw, name: target.name, problem)
  }

  /// Tries `update.lock` every `pollInterval` for up to `lockTimeout`.
  private func acquireLock(_ slug: String) async -> RemovalLockAttempt {
    var waited: Duration = .zero
    while true {
      switch lock.tryAcquire() {
      case .acquired(let release): return .acquired(release: release)
      case .failed(let reason):
        await note(slug, "cannot take update.lock: \(reason)")
        return .failed(reason)
      case .busy:
        guard waited < Self.lockTimeout else {
          await note(slug, "update.lock still held after \(Self.lockTimeout.components.seconds) s")
          return .busy
        }
        await sleep(Self.pollInterval)
        waited += Self.pollInterval
      }
    }
  }

  /// Asks a running app to quit and polls until it is idle; false when it still runs after `quitTimeout`.
  private func quitIfRunning(_ target: RemovalTarget) async -> Bool {
    let slug = target.slug.raw
    guard await isRunning(target) else {
      await note(slug, "not running")
      return true
    }
    let sent = await quitter.requestQuit(bundleId: target.bundleId)
    await note(slug, sent ? "quit requested" : "running, but no app process took the quit request")
    var waited: Duration = .zero
    while await isRunning(target) {
      guard waited < Self.quitTimeout else {
        await note(slug, "did not quit in \(Self.quitTimeout.components.seconds) s")
        return false
      }
      await sleep(Self.pollInterval)
      waited += Self.pollInterval
    }
    await note(slug, "closed")
    return true
  }

  private func isRunning(_ target: RemovalTarget) async -> Bool {
    await running.isRunning(bundleId: target.bundleId, profileDir: target.profileDir)
  }

  /// The app first: if it cannot be moved, nothing else is. Then the rest item by item, then the record. Each item is
  /// compared with what was checked right before it moves; one swapped since then stays where it is.
  private func trashAndForget(_ target: RemovalTarget, mode: RemovalMode) async -> RemovalReport {
    let slug = target.slug.raw
    var trashed: [RemovalItem] = []
    var failed: [(RemovalItem, String)] = []
    for item in target.items(mode) {
      switch target.state(of: item.url) {
      case .gone:
        await note(slug, "\(item.kind.rawValue) not on disk: \(item.url.path)")
        continue
      case .changed:
        await note(slug, "\(item.kind.rawValue) changed since the check, left in place: \(item.url.path)")
        guard item.kind != .app else {
          let refusal = ClonePathRefusal.changed(name: target.name, path: tilde(item.url))
          return .refused(slug: slug, name: target.name, refusal.userMessage, notTrashed: [item.url])
        }
        failed.append((item, BuilderText.string("remove.changed")))
        continue
      case .unchanged: break
      }
      do {
        let landed = try trasher.trash(item.url)
        await note(slug, "trashed \(item.url.path)" + (landed.map { " → \($0.path)" } ?? ""))
        trashed.append(item)
        if item.kind == .app { await unregister(slug, [item.url] + (landed.map { [$0] } ?? [])) }
      } catch {
        await note(slug, "cannot trash \(item.url.path): \(error)")
        guard item.kind != .app else {
          let problem = BuilderText.format("remove.trash-failed", target.name, error.localizedDescription)
          return .refused(slug: slug, name: target.name, problem, notTrashed: [item.url])
        }
        failed.append((item, error.localizedDescription))
      }
    }
    let recordRemoved = await forget(target)
    var problems: [String] = []
    if !failed.isEmpty {
      if !trashed.isEmpty {
        let moved = trashed.map { label($0, target) }.joined(separator: ", ")
        problems.append(BuilderText.format("remove.trashed", moved))
      }
      problems += failed.map { BuilderText.format("remove.not-trashed", label($0.0, target), $0.1) }
    }
    if !recordRemoved {
      problems.append(BuilderText.format("remove.record-kept", target.name))
    }
    return RemovalReport(
      slug: slug, name: target.name, trashed: trashed.map(\.url), notTrashed: failed.map(\.0.url),
      recordRemoved: recordRemoved, problems: problems)
  }

  /// `lsregister -u` for the old place and the Trash copy; a failure is only logged (nothing the user can do).
  private func unregister(_ slug: String, _ apps: [URL]) async {
    for app in apps {
      do {
        try await unregistrar.unregister(app)
      } catch {
        await note(slug, "lsregister -u \(app.path) failed: \(error)")
      }
    }
  }

  private func forget(_ target: RemovalTarget) async -> Bool {
    do {
      _ = try await store.removeEntry(slug: target.slug)
      await note(target.slug.raw, "removed from instances.json")
      return true
    } catch {
      await note(target.slug.raw, "cannot remove from instances.json: \(error)")
      return false
    }
  }

  private func label(_ item: RemovalItem, _ target: RemovalTarget) -> String {
    switch item.kind {
    case .app: BuilderText.format("remove.item.app", target.name)
    case .backup: BuilderText.format("remove.item.backup", tilde(item.url))
    case .staging: BuilderText.format("remove.item.staging", tilde(item.url))
    case .profile: BuilderText.format("remove.item.profile", tilde(item.url))
    }
  }

  /// `~/…` for paths in the home folder.
  private func tilde(_ url: URL) -> String { ClonePathPolicy.tilde(url, home: paths.home) }

  private func note(_ slug: String, _ detail: String) async {
    await log.write("remove \(slug): \(detail)", category: Self.logCategory)
  }

  /// `"Claude mv2"` → `"mv2"`: the part the add window asks for.
  static func shortName(_ name: String) -> String {
    name.hasPrefix("Claude ") ? String(name.dropFirst("Claude ".count)) : name
  }

  /// `[legacy-]<appName>.<yyyyMMdd-HHmmss>` real directories in `backupDir`, sorted by name.
  static func backups(of appName: String, in backupDir: URL) -> [URL] {
    let pattern = "^(\(NSRegularExpression.escapedPattern(for: BackupPlan.legacyPrefix)))?"
      + "\(NSRegularExpression.escapedPattern(for: appName))\\.[0-9]{8}-[0-9]{6}$"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? []
    return names.filter { $0.range(of: pattern, options: .regularExpression) != nil }.sorted()
      .map { backupDir.appendingPathComponent($0, isDirectory: true) }
      .filter(isRealDirectory)
  }

  static func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }
}
