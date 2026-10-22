import Foundation
import os
import Support

/// What «Сохранить» in the «Изменить…» window asks for: a new app name and icon label. The slug, bundle id and
/// profile folder never change, so the account stays signed in. «Переустановить» is a change with `reinstall` set:
/// the same name and label rebuilt from the current official app (a fresh icon, no Claude update needed).
public struct InstanceChange: Sendable, Equatable {
  public let slug: Slug
  public let name: String
  public let badge: String
  /// Rebuild even when nothing changes; with a new name or label it is an ordinary edit.
  public let reinstall: Bool

  /// Both values are trimmed like `InstanceDraft`.
  public init(slug: Slug, name: String, badge: String, reinstall: Bool = false) {
    let draft = InstanceDraft(name: name, badge: badge)
    self.slug = slug
    self.name = draft.name
    self.badge = draft.badge
    self.reinstall = reinstall
  }
}

/// Where a running edit is, for the window's progress line.
public enum EditStage: Sendable, Equatable {
  case building, closing, installing, reopening
}

/// What a finished edit did. `warnings` are lines (UI language) about steps after the install that did not work out
/// (the edit itself stands).
public struct EditOutcome: Sendable, Equatable {
  public let instance: Instance
  public let renamed: Bool
  public let wasRunning: Bool
  public let reopened: Bool
  public let warnings: [String]

  public init(instance: Instance, renamed: Bool, wasRunning: Bool, reopened: Bool, warnings: [String]) {
    self.instance = instance
    self.renamed = renamed
    self.wasRunning = wasRunning
    self.reopened = reopened
    self.warnings = warnings
  }
}

/// Rebuilds a cmacc-built clone from the official app with a new name and/or label (or, for a reinstall, the same
/// ones): staging build → verify → (quit the running clone) → swap in place, or move to `<Applications>/<new name>.app`
/// → register → `instances.json` → LaunchServices forgets the previous bundle (the backup of a swap; the old bundle of
/// a rename, which then goes to the Trash) → reopen. Until `instances.json` is written every step is undone on failure.
/// Only an app `ClonePathPolicy` accepts is edited, and it is compared with what was checked before it is swapped,
/// set aside or trashed.
public struct EditInstance: Sendable {
  public protocol Store: Sendable {
    func load() async throws -> [Instance]
    func upsert(_ instance: Instance) async throws -> [Instance]
  }

  /// Drops an app bundle from LaunchServices (`lsregister -u`).
  public protocol Unregistering: Sendable {
    func unregister(_ app: URL) async throws
  }

  /// Moves a file or folder to the user's Trash — never a permanent delete.
  public protocol Trashing: Sendable {
    func trash(_ item: URL) async throws
  }

  /// Replaces the installed bundle with a staged one in place; returns where the previous bundle was kept. Refuses
  /// (`SwapError.liveChanged`) when `live` is no longer `expectedLive`, the app checked before the build.
  public protocol Swapping: Sendable {
    func swap(live: URL, staged: URL, expectedLive: FileIdentity) async throws -> URL
  }

  public struct Effects: Sendable {
    let store: any Store
    let builder: any CloneBuilding
    let running: any RunningChecking
    let quitter: any AppQuitting
    let opener: any AppOpening
    let registrar: any AppRegistering
    let unregistrar: any Unregistering
    let trash: any Trashing
    let swapper: any Swapping
    let mover: FileMover

    public init(
      store: any Store, builder: any CloneBuilding, running: any RunningChecking, quitter: any AppQuitting,
      opener: any AppOpening, registrar: any AppRegistering, unregistrar: any Unregistering, trash: any Trashing,
      swapper: any Swapping, mover: FileMover = .live
    ) {
      self.store = store
      self.builder = builder
      self.running = running
      self.quitter = quitter
      self.opener = opener
      self.registrar = registrar
      self.unregistrar = unregistrar
      self.trash = trash
      self.swapper = swapper
      self.mover = mover
    }
  }

  static let pollInterval: Duration = .milliseconds(500)
  static let quitTimeout: Duration = .seconds(30)
  /// An update pass holds `update.lock` for about 6 s per rebuilt clone: up to 24 tries, 5 s apart.
  static let lockAttempts = 24
  static let lockRetry: Duration = .seconds(5)

  let paths: Paths
  let effects: Effects
  let officialApp: URL
  let sleep: @Sendable (Duration) async -> Void
  let log = AppLog.logger("edit-instance")

  public init(
    paths: Paths, effects: Effects,
    officialApp: URL = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true),
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.paths = paths
    self.effects = effects
    self.officialApp = officialApp
    self.sleep = sleep
  }

  /// Applies `change`; `identity` must be the permanent one. Throws `EditInstanceError` for refusals and failures
  /// (anything thrown by the build pipeline passes through); nothing is changed when it throws.
  public func apply(
    _ change: InstanceChange, identity: SigningIdentity,
    progress: @escaping @Sendable (EditStage) async -> Void = { _ in }
  ) async throws -> EditOutcome {
    guard identity != .adhoc else { throw EditInstanceError.adhocIdentity }
    let plan = try await prepare(change)
    await progress(.building)
    // Held from the build on: an update pass discards this clone's staging builds before building its own.
    let lock = try await acquireLock()
    defer { lock?.release() }
    let staged = try await build(plan, identity: identity)
    let wasRunning = try await closeIfRunning(plan, staged: staged, progress: progress)
    await progress(.installing)
    let placed = try await installReopeningOnFailure(plan, staged: staged, wasRunning: wasRunning)
    var warnings = await finish(plan, placed: placed)
    var reopened = false
    if wasRunning {
      await progress(.reopening)
      reopened = await reopen(plan.newApp, name: placed.instance.name, warnings: &warnings)
    }
    let verb = plan.changesNothing ? "reinstalled" : "edited"
    let app = plan.newApp.lastPathComponent
    log.info("\(verb, privacy: .public) \(plan.instance.slug.raw, privacy: .public): \(app, privacy: .public)")
    return EditOutcome(instance: placed.instance, renamed: plan.kind != .inPlace, wasRunning: wasRunning,
                       reopened: reopened, warnings: warnings)
  }

  /// Where a rename would put the app (next to the current one), nil when the name keeps the file name (letter case
  /// aside: the Applications folder ignores it, so such a rename never clashes).
  public static func renameTarget(of instance: Instance, to name: String) -> URL? {
    guard let appPath = instance.appPath else { return nil }
    let plan = EditPlan.kind(oldApp: URL(fileURLWithPath: appPath, isDirectory: true), name: name)
    return plan.kind == .rename ? plan.newApp : nil
  }

  // MARK: Steps

  private func prepare(_ change: InstanceChange) async throws -> EditPlan {
    let existing: [Instance]
    do {
      existing = try await effects.store.load()
    } catch {
      throw EditInstanceError.storeUnreadable(String(describing: error))
    }
    guard let instance = existing.first(where: { $0.slug == change.slug }) else {
      throw EditInstanceError.notFound(change.slug.raw)
    }
    let spec = try Self.editableSpec(instance)
    let app: CheckedPath
    do {
      app = try ClonePathPolicy(home: paths.home, officialApp: officialApp).checkApp(instance, others: existing)
    } catch let refusal as ClonePathRefusal {
      log.error("refused \(instance.slug.raw, privacy: .public): \(refusal.description, privacy: .public)")
      throw EditInstanceError.unsafePath(refusal)
    }
    let problems = InstanceDraft(name: change.name, badge: change.badge).problems(existing: existing, editing: change.slug)
    guard problems.isEmpty else { throw EditInstanceError.invalid(problems) }
    let plan = EditPlan(instance: instance, spec: spec, change: change, checkedApp: app)
    guard change.reinstall || !plan.changesNothing else { throw EditInstanceError.nothingToChange }
    if plan.kind == .rename, FileManager.default.fileExists(atPath: plan.newApp.path) {
      throw EditInstanceError.targetExists(plan.newApp.path)
    }
    return plan
  }

  /// Why `instance` cannot be edited; nil when it can (a clone built by ClaudeMultiAcc with a complete entry).
  public static func refusal(for instance: Instance) -> EditRefusal? {
    do {
      _ = try editableSpec(instance)
      return nil
    } catch EditInstanceError.notEditable(_, let reason) {
      return reason
    } catch {
      return .incomplete
    }
  }

  /// Only clones built by ClaudeMultiAcc, with everything needed to rebuild them.
  static func editableSpec(_ instance: Instance) throws -> CloneSpec {
    switch instance.kind {
    case .official: throw EditInstanceError.notEditable(name: instance.name, reason: .official)
    case .cliOnly: throw EditInstanceError.notEditable(name: instance.name, reason: .noApp)
    case .clone: break
    }
    guard instance.builtBy == "cmacc" else { throw EditInstanceError.notEditable(name: instance.name, reason: .legacy) }
    guard instance.appPath != nil, let spec = try? CloneSpec.from(instance: instance) else {
      throw EditInstanceError.notEditable(name: instance.name, reason: .incomplete)
    }
    return spec
  }

  /// A verified staging build of the new spec; an unverified one is removed and nothing else happens.
  private func build(_ plan: EditPlan, identity: SigningIdentity) async throws -> URL {
    let report = try await effects.builder.build(spec: plan.spec, source: officialApp, identity: identity, intent: .stagingOnly)
    let staged = URL(fileURLWithPath: report.stagedPath, isDirectory: true)
    guard report.verified else {
      discardBuild(staged)
      throw EditInstanceError.notVerified(step: report.failure?.step)
    }
    return staged
  }

  /// `update.lock`, so no update pass builds or swaps this clone meanwhile. Busy for two minutes → `.busy`; a lock
  /// file that cannot be opened at all blocks every pass too, so the edit goes on without it.
  private func acquireLock() async throws -> UpdateLock? {
    for attempt in 1...Self.lockAttempts {
      switch UpdateLock.acquire(UpdateLock.file(paths)) {
      case .acquired(let lock): return lock
      case .failed(let code):
        log.error("cannot open update.lock (errno \(code)); editing without it")
        return nil
      case .busy:
        if attempt < Self.lockAttempts { await sleep(Self.lockRetry) }
      }
    }
    throw EditInstanceError.busy
  }

  /// Asks a running clone to quit and waits until it is idle; returns whether it was running. A clone that keeps
  /// running is left alone and the build removed.
  private func closeIfRunning(
    _ plan: EditPlan, staged: URL, progress: @Sendable (EditStage) async -> Void
  ) async throws -> Bool {
    guard await isBusy(plan) else { return false }
    await progress(.closing)
    let sent = await effects.quitter.requestQuit(bundleId: plan.spec.bundleId)
    log.info("quit \(plan.instance.slug.raw, privacy: .public): \(sent ? "requested" : "no process took it", privacy: .public)")
    var waited: Duration = .zero
    while await isBusy(plan) {
      guard waited < Self.quitTimeout else {
        discardBuild(staged)
        throw EditInstanceError.stillRunning(plan.instance.name)
      }
      await sleep(Self.pollInterval)
      waited += Self.pollInterval
    }
    return true
  }

  private func isBusy(_ plan: EditPlan) async -> Bool {
    await effects.running.isRunning(bundleId: plan.spec.bundleId, profileDir: plan.spec.profileDir)
  }

  private func installReopeningOnFailure(
    _ plan: EditPlan, staged: URL, wasRunning: Bool
  ) async throws -> PlacedEdit {
    do {
      return try await install(plan, staged: staged)
    } catch {
      discardBuild(staged)
      if wasRunning { try? await effects.opener.open(app: plan.oldApp) }
      throw error
    }
  }

  private func reopen(_ app: URL, name: String, warnings: inout [String]) async -> Bool {
    do {
      try await effects.opener.open(app: app)
      return true
    } catch {
      log.error("reopen \(app.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
      warnings.append(BuilderText.format("edit.reopen-failed", name))
      return false
    }
  }

  /// Removes one build dir directly inside staging (never a waiting update build of the same clone).
  func discardBuild(_ staged: URL) {
    let dir = staged.deletingLastPathComponent()
    let staging = StagingArea(paths: paths)
    guard staging.contains(dir),
          StagingArea.resolvedPath(dir.deletingLastPathComponent()) == StagingArea.resolvedPath(staging.root)
    else { return }
    do {
      try FileManager.default.removeItem(at: dir)
    } catch {
      log.error("cannot remove \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }
}

/// The edit worked out before anything is touched: old and new location of the app, and the spec to build.
struct EditPlan: Sendable {
  enum Kind: Sendable, Equatable {
    /// Same file name: the staged build replaces the app in place.
    case inPlace
    /// A new file name next to the old one.
    case rename
    /// Only the letter case of the file name changes: the old bundle is set aside first.
    case caseRename
  }

  let instance: Instance
  let spec: CloneSpec
  let oldApp: URL
  let newApp: URL
  let kind: Kind
  /// The installed app as `ClonePathPolicy` checked it in `prepare`.
  let checkedApp: CheckedPath
  /// Same name, label and file name: only a reinstall rebuilds it.
  let changesNothing: Bool

  init(instance: Instance, spec: CloneSpec, change: InstanceChange, checkedApp: CheckedPath) {
    self.instance = instance
    self.checkedApp = checkedApp
    self.spec = CloneSpec(
      slug: spec.slug, displayName: change.name, bundleId: spec.bundleId, profileDir: spec.profileDir, badge: change.badge)
    let old = URL(fileURLWithPath: instance.appPath ?? "/", isDirectory: true)
    let target = Self.kind(oldApp: old, name: change.name)
    oldApp = old
    newApp = target.newApp
    kind = target.kind
    changesNothing = change.name == instance.name && change.badge == instance.badge && target.kind == .inPlace
  }

  /// The refusal to raise when the installed app is no longer the one checked.
  func appChanged(home: URL) -> EditInstanceError {
    .unsafePath(.changed(name: instance.name, path: ClonePathPolicy.tilde(oldApp, home: home)))
  }

  static func kind(oldApp: URL, name: String) -> (newApp: URL, kind: Kind) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let newApp = oldApp.deletingLastPathComponent().appendingPathComponent("\(trimmed).app", isDirectory: true)
    if newApp.lastPathComponent == oldApp.lastPathComponent { return (oldApp, .inPlace) }
    let oldName = oldApp.deletingPathExtension().lastPathComponent
    return (newApp, InstanceDraft.isSameName(oldName, trimmed) ? .caseRename : .rename)
  }

  /// The registry entry after the edit: new name, label and location; a fresh build supersedes any waiting one.
  var edited: Instance {
    Instance(
      slug: instance.slug, name: spec.displayName, kind: instance.kind, bundleId: instance.bundleId,
      appPath: newApp.path, profileDir: instance.profileDir, accountUuid: instance.accountUuid,
      orgUuid: instance.orgUuid, emails: instance.emails, cliConfigDir: instance.cliConfigDir, badge: spec.badge,
      builtBy: "cmacc", pendingBuild: nil)
  }
}
