import Foundation
import os
import Support

/// What the watcher did (or would do) for one clone; `line` is what `updates.log` records.
public struct UpdateDecision: Sendable, Equatable {
  public enum Action: String, Sendable {
    case skip, retry, needsIdentity = "needs-identity", wouldRebuild = "would-rebuild", swap, pending, fail
    /// A verified build for the current source version waits for the running clone to quit.
    case pendingWaiting = "pending-waiting"
    /// Another process holds `<data>/update.lock` (the app and the LaunchAgent share it).
    case skippedLocked = "skipped-locked"
    /// Requested while this watcher was mid-pass: folded into one more pass after it.
    case coalesced
  }

  public let slug: String
  public let action: Action
  public let detail: String

  public init(slug: String, action: Action, detail: String) {
    self.slug = slug
    self.action = action
    self.detail = detail
  }

  public var line: String { "\(action.rawValue) \(slug): \(detail)" }

  /// The `skip` detail while `updates.autoRebuild` is off in settings.json.
  public static let autoRebuildOff = "auto-rebuild disabled"
  /// The slug of a decision about the whole pass (locked, coalesced, registry unreadable), not one clone.
  public static let everyClone = "all"
}

/// Rebuilds every cmacc-built clone forward-only from the newest Claude (G20: any number of clones, in `instances.json`
/// order): the official app after it updates, or a verified download that is newer (`ClaudeSourceStore.newest()`,
/// derived from `paths` and `officialApp`). Legacy clones (`builtBy != "cmacc"`) are never touched. A running clone
/// keeps running: its verified build waits in `pendingBuild`.
public actor UpdateWatcher {
  static let debounce: TimeInterval = 30
  static let hourly: Duration = .seconds(3600)
  static let shipItRetry: Duration = .seconds(600)
  /// After a clone quits: how long to wait for it to become idle, and how often to look.
  static let quitSettle: Duration = .seconds(30)
  static let idlePoll: Duration = .milliseconds(500)
  /// `applyPendingNow()` outlasts a running pass (about 6 s per rebuilt clone): up to 24 tries, 5 s apart.
  static let applyAttempts = 24
  static let applyRetry: Duration = .seconds(5)

  let paths: Paths
  let store: InstanceStore
  let pipeline: any CloneBuilding
  let running: any RunningChecking
  let vendorShipIt: any VendorUpdateChecking
  let registrar: any AppRegistering
  let log: RedactingFileLog
  let clock: any Support.Clock
  let identity: @Sendable () async -> SigningIdentity?
  let officialApp: URL
  let timeZone: TimeZone
  let sleep: @Sendable (Duration) async -> Void
  private var watcher: DirectoryWatcher?
  private var timers: [Task<Void, Never>] = []
  private(set) var isEvaluating = false
  private var rerunRequested = false
  /// One of the requests folded into the coming pass was manual.
  private var rerunManual = false
  /// Runs after every applying pass that ran (the menu re-reads versions and the registry).
  private var passFinished: (@Sendable () async -> Void)?

  public init(
    paths: Paths, store: InstanceStore, pipeline: any CloneBuilding, running: any RunningChecking,
    vendorShipIt: any VendorUpdateChecking, registrar: any AppRegistering, log: RedactingFileLog, clock: any Support.Clock,
    identity: @escaping @Sendable () async -> SigningIdentity?,
    officialApp: URL = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true), timeZone: TimeZone = .current,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.paths = paths
    self.store = store
    self.pipeline = pipeline
    self.running = running
    self.vendorShipIt = vendorShipIt
    self.registrar = registrar
    self.log = log
    self.clock = clock
    self.identity = identity
    self.officialApp = officialApp
    self.timeZone = timeZone
    self.sleep = sleep
  }

  /// One full pass that builds and swaps (the in-app watcher, a newly stored download and
  /// `cmacc update check --apply-when-idle`).
  public func handleOfficialChange() async -> [UpdateDecision] {
    await evaluate(apply: true)
  }

  /// One pass over the clones; with `apply: false` nothing is built (`would-rebuild` instead). A `manual` pass («Обновить»
  /// in the menu) builds even while `updates.autoRebuild` is off. Applying passes never overlap: within this watcher a
  /// request during a pass is coalesced into one more pass after it, and across processes `<data>/update.lock` admits
  /// one pass at a time.
  public func evaluate(apply: Bool, manual: Bool = false) async -> [UpdateDecision] {
    guard apply else { return await pass(apply: false, manual: manual) }
    guard !isEvaluating else {
      rerunRequested = true
      rerunManual = rerunManual || manual
      return [await record(UpdateDecision(slug: "all", action: .coalesced, detail: "a pass is running; one more follows it"))]
    }
    isEvaluating = true
    defer { isEvaluating = false }
    let lock: UpdateLock
    switch UpdateLock.acquire(lockFile) {
    case .acquired(let acquired): lock = acquired
    case .busy:
      return [await record(UpdateDecision(slug: "all", action: .skippedLocked, detail: "another pass holds update.lock"))]
    case .failed(let code):
      return [await record(UpdateDecision(slug: "all", action: .fail, detail: "cannot lock update.lock (errno \(code))"))]
    }
    defer { lock.release() }
    var decisions = await pass(apply: true, manual: manual)
    while rerunRequested {
      let manual = rerunManual
      rerunRequested = false
      rerunManual = false
      decisions = await pass(apply: true, manual: manual)
    }
    await passFinished?()
    return decisions
  }

  public func onPassFinished(_ handler: @escaping @Sendable () async -> Void) {
    passFinished = handler
  }

  /// Waits (bounded) for a running pass to end, so quitting the app never cuts a swap in half; true when idle.
  public func waitUntilIdle(timeout: Duration) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while isEvaluating, ContinuousClock.now < deadline { await sleep(Self.idlePoll) }
    return !isEvaluating
  }

  var lockFile: URL { UpdateLock.file(paths) }

  /// The official app and the downloads under `<data>/source`; each pass builds from its `newest()`.
  var sources: ClaudeSourceStore { ClaudeSourceStore(paths: paths, officialApp: officialApp) }

  func record(_ decision: UpdateDecision) async -> UpdateDecision {
    await log.write(decision.line, category: "updates")
    return decision
  }

  private func pass(apply: Bool, manual: Bool) async -> [UpdateDecision] {
    let instances: [Instance]
    do {
      instances = try await store.load()
    } catch {
      await log.write("fail all: cannot read instances.json: \(error)", category: "updates")
      return []
    }
    let settings = await SettingsStore(file: paths.settingsFile).load()
    let source = sources.newest()
    var decisions: [UpdateDecision] = []
    for instance in instances where instance.kind == .clone {
      let autoRebuild = manual || settings.updates.autoRebuild
      let decision = await decide(instance, source: source, autoRebuild: autoRebuild, apply: apply)
      decisions.append(await record(decision))
    }
    if apply, decisions.contains(where: { $0.action == .retry }) { scheduleRetry() }
    return decisions
  }

  /// FSEvents on `<official>/Contents` (Info.plist, 30 s debounce) plus an hourly pass.
  public func start() {
    guard watcher == nil else { return }
    let created = DirectoryWatcher(paths: [officialApp.appendingPathComponent("Contents")], latency: Self.debounce) { urls in
      guard urls.contains(where: { $0.lastPathComponent == "Info.plist" }) else { return }
      Task { _ = await self.handleOfficialChange() }
    }
    created.start()
    watcher = created
    timers.append(Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.hourly)
        if Task.isCancelled { return }
        _ = await self.handleOfficialChange()
      }
    })
  }

  public func stop() {
    watcher?.stop()
    watcher = nil
    timers.forEach { $0.cancel() }
    timers = []
  }

  private func scheduleRetry() {
    timers.append(Task {
      try? await Task.sleep(for: Self.shipItRetry)
      if Task.isCancelled { return }
      _ = await self.handleOfficialChange()
    })
  }
}

extension UpdateWatcher {
  /// The real machine: builder pipeline (badge baked into `electron.icns`, no Dock-tile plugin),
  /// NSRunningApplication/lsappinfo/lock, ShipIt check, `lsregister`, `~/Library/Logs/ClaudeMultiAcc/updates.log` and
  /// the permanent identity (read-only keychain lookup).
  public static func live(paths: Paths, runner: ProcessRunning, launcherBinary: URL) -> UpdateWatcher {
    let official = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
    let identityCheck = SigningIdentityCheck(paths: paths, runner: runner)
    return UpdateWatcher(
      paths: paths, store: InstanceStore(paths: paths),
      pipeline: InstanceBuildPipeline(paths: paths, runner: runner, launcherBinary: launcherBinary, clock: SystemClock()),
      running: RunningCheck(runner: runner), vendorShipIt: VendorUpdateCheck(runner: runner, sourceApp: official),
      registrar: Registrar(runner: runner, staging: StagingArea(paths: paths)),
      log: RedactingFileLog(url: paths.logsDir.appendingPathComponent("updates.log")), clock: SystemClock(),
      identity: { await identityCheck.permanentIdentity() }, officialApp: official)
  }
}
