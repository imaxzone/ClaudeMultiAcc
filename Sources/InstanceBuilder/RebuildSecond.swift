import Foundation
import os
import Support

/// Everything `RebuildSecond` touches, injectable so tests run against temp dirs and fakes (G5, G6).
public struct RebuildEnvironment: Sendable {
  public let applicationsDir: URL
  public let paths: Paths
  public let running: any RunningChecking
  public let ancestry: AncestryCheck
  public let identity: SigningIdentityCheck
  public let pipeline: any CloneBuilding
  public let registrar: any AppRegistering
  public let clock: any Support.Clock
  public let vendorUpdate: any VendorUpdateChecking
  public let sourceProbe: @Sendable (URL) async throws -> SourceInfo
  public let availableBytes: @Sendable (URL) -> Int64?
  public let directorySize: @Sendable (URL) -> Int64
  public let volume: @Sendable (URL) -> String?
  /// `CLAUDE_CODE_DESKTOP_APP_VERSION` of the current session, if any.
  public let hostAppVersion: String?
  public let timeZone: TimeZone
  public let mover: FileMover

  public init(
    applicationsDir: URL, paths: Paths, running: any RunningChecking, ancestry: AncestryCheck,
    identity: SigningIdentityCheck, pipeline: any CloneBuilding, registrar: any AppRegistering, clock: any Support.Clock,
    vendorUpdate: any VendorUpdateChecking, sourceProbe: @escaping @Sendable (URL) async throws -> SourceInfo,
    availableBytes: @escaping @Sendable (URL) -> Int64?, directorySize: @escaping @Sendable (URL) -> Int64,
    volume: @escaping @Sendable (URL) -> String?, hostAppVersion: String?, timeZone: TimeZone = .current,
    mover: FileMover = .live
  ) {
    self.applicationsDir = applicationsDir
    self.paths = paths
    self.running = running
    self.ancestry = ancestry
    self.identity = identity
    self.pipeline = pipeline
    self.registrar = registrar
    self.clock = clock
    self.vendorUpdate = vendorUpdate
    self.sourceProbe = sourceProbe
    self.availableBytes = availableBytes
    self.directorySize = directorySize
    self.volume = volume
    self.hostAppVersion = hostAppVersion
    self.timeZone = timeZone
    self.mover = mover
  }

  /// The same environment with other renames (tests fail chosen steps).
  public func with(mover: FileMover) -> RebuildEnvironment {
    RebuildEnvironment(
      applicationsDir: applicationsDir, paths: paths, running: running, ancestry: ancestry, identity: identity,
      pipeline: pipeline, registrar: registrar, clock: clock, vendorUpdate: vendorUpdate,
      sourceProbe: sourceProbe,
      availableBytes: availableBytes, directorySize: directorySize, volume: volume, hostAppVersion: hostAppVersion,
      timeZone: timeZone, mover: mover)
  }

  public var sourceApp: URL { applicationsDir.appendingPathComponent("Claude.app", isDirectory: true) }
  public var spec: CloneSpec { CloneSpec.second(home: paths.home) }
  public var liveApp: URL { applicationsDir.appendingPathComponent("\(spec.displayName).app", isDirectory: true) }
}

public struct ApplyResult: Sendable, Equatable {
  public let live: URL
  public let backup: URL
  /// Completed steps in order: check, build, swap, register, requirement, store.
  public let steps: [String]

  public var rollbackCommand: String { "cmacc instance rollback second \(backup.path)" }
}

/// Step 6: rebuild the legacy `Claude 2nd.app` with the builder. Only `check` runs in this project's session;
/// `apply` and `rollback` are covered by hermetic tests (G5).
public struct RebuildSecond: Sendable {
  let env: RebuildEnvironment
  let log = AppLog.logger("rebuild-second")

  public init(env: RebuildEnvironment) {
    self.env = env
  }

  /// The ten preflight items in print order. Read-only outside the data dir; the staging build is discarded
  /// afterwards unless `keepStaging`. Holds `<data>/update.lock`; when another pass holds it, only a failed
  /// `update-lock` item is returned and nothing is built or discarded.
  public func check(keepStaging: Bool) async -> [PreflightItem] {
    switch acquireLock() {
    case .failure(let refusal): return [refusal.item]
    case .success(let lock):
      defer { lock.release() }
      return await checks(keepStaging: keepStaging)
    }
  }

  private func checks(keepStaging: Bool) async -> [PreflightItem] {
    let spec = env.spec
    var items = [
      PreflightItem(id: PreflightItem.updateLock, passed: true, detail: "free"),
      await PreflightCheck.notRunning(env, spec: spec),
      PreflightCheck.notHostedInside(env, live: env.liveApp),
      await PreflightCheck.identityPresent(env),
      PreflightCheck.diskSpace(env, source: env.sourceApp),
      await PreflightCheck.vendorIdle(env.vendorUpdate),
      await PreflightCheck.sourceOK(env, source: env.sourceApp),
    ]
    let (buildItem, staged) = await stagingBuild(spec: spec)
    items.append(buildItem)
    let plan = BackupPlan(backupDir: env.paths.backupDir, appName: env.liveApp.lastPathComponent, now: env.clock.now,
                          timeZone: env.timeZone, prefix: await backupPrefix())
    items.append(plan.evaluate(applicationsDir: env.applicationsDir, volume: env.volume))
    items.append(PreflightCheck.profileIntact(spec: spec, stagedApp: staged))
    if !keepStaging { discardStaging(spec.slug) }
    return items
  }

  /// check (all pass) → build with the permanent identity (badge baked in) → swap → register → requirement → store.
  /// Once the new app is registered, LaunchServices forgets the backup (a failure is only logged to updates.log).
  public func apply() async throws -> ApplyResult {
    let lock: UpdateLock
    switch acquireLock() {
    case .failure(let refusal): throw RebuildError.preflightFailed([refusal.item.id])
    case .success(let acquired): lock = acquired
    }
    defer { lock.release() }
    let failed = await checks(keepStaging: false).filter { !$0.passed }.map(\.id)
    guard failed.isEmpty else { throw RebuildError.preflightFailed(failed) }
    var steps = ["check"]
    guard let identity = await env.identity.permanentIdentity() else { throw RebuildError.noPermanentIdentity }
    let report = try await env.pipeline.build(spec: env.spec, source: env.sourceApp, identity: identity, intent: .install)
    guard report.verified else { throw RebuildError.notVerified(report.failure.map { "\($0.step): \($0.message)" } ?? "unverified") }
    steps.append("build")
    // The builds take minutes: Claude 2nd may have been launched meanwhile. Re-check right before the swap.
    guard await isIdleAndNotHosted() else {
      log.error("Claude 2nd started during the build; staged build kept at \(report.stagedPath, privacy: .public)")
      throw RebuildError.targetRunning(env.spec.bundleId)
    }
    let prefix = await backupPrefix()
    let backup = try BundleSwapper.swap(
      live: env.liveApp, staged: URL(fileURLWithPath: report.stagedPath, isDirectory: true),
      backupDir: env.paths.backupDir, now: env.clock.now, timeZone: env.timeZone, backupPrefix: prefix, mover: env.mover)
    steps.append("swap")
    log.info("swapped \(env.liveApp.path, privacy: .public); backup \(backup.path, privacy: .public)")
    try await afterSwap("register", backup: backup) {
      guard await isIdleAndNotHosted() else { throw RebuildError.targetRunning(env.spec.bundleId) }
      try await env.registrar.register(env.liveApp)
    }
    steps.append("register")
    await forget(backup)
    try await afterSwap("requirement", backup: backup) { try writeRequirement(report) }
    steps.append("requirement")
    try await afterSwap("store", backup: backup) { try await markRebuilt() }
    steps.append("store")
    return ApplyResult(live: env.liveApp, backup: backup, steps: steps)
  }

  private struct LockRefusal: Error {
    let item: PreflightItem
  }

  /// The update lock, or the failed `update-lock` item.
  private func acquireLock() -> Result<UpdateLock, LockRefusal> {
    switch UpdateLock.acquire(UpdateLock.file(env.paths)) {
    case .acquired(let lock): return .success(lock)
    case .busy:
      return .failure(LockRefusal(item: PreflightItem(
        id: PreflightItem.updateLock, passed: false, detail: "another pass holds update.lock — retry in a minute")))
    case .failed(let code):
      return .failure(LockRefusal(item: PreflightItem(
        id: PreflightItem.updateLock, passed: false, detail: "cannot lock update.lock (errno \(code))")))
    }
  }

  /// "legacy-" while `second` is still the legacy-script build (read-only: seeds when `instances.json` is missing).
  /// Fails closed: when the list cannot be read, the backup is still marked `legacy-` so it is never pruned.
  func backupPrefix() async -> String {
    let instances: [Instance]
    do {
      instances = try await InstanceStore(paths: env.paths).load()
    } catch {
      let detail = SecretRedactor.redact(String(describing: error))
      log.error("cannot read instances.json (\(detail, privacy: .public)); naming the backup legacy- to protect it")
      return BackupPlan.legacyPrefix
    }
    let second = instances.first { $0.slug == env.spec.slug }
    return second?.builtBy == "legacy-script" ? BackupPlan.legacyPrefix : ""
  }

  /// The `not-running` and `not-hosted-inside` items, evaluated again.
  private func isIdleAndNotHosted() async -> Bool {
    let running = await PreflightCheck.notRunning(env, spec: env.spec)
    return running.passed && PreflightCheck.notHostedInside(env, live: env.liveApp).passed
  }

  private func stagingBuild(spec: CloneSpec) async -> (PreflightItem, URL?) {
    let permanent = await env.identity.permanentIdentity()
    do {
      let report = try await env.pipeline.build(
        spec: spec, source: env.sourceApp, identity: permanent ?? .adhoc, intent: .stagingOnly)
      let staged = URL(fileURLWithPath: report.stagedPath, isDirectory: true)
      guard report.verified else {
        let why = report.failure.map { "failed at \($0.step): \($0.message)" } ?? "not verified"
        return (PreflightItem(id: PreflightItem.stagingBuild, passed: false, detail: why), staged)
      }
      let kind = permanent == nil ? "adhoc — apply needs the permanent identity" : "permanent identity"
      let smoke = "\(report.smoke.filter(\.passed).count)/\(report.smoke.count) smoke"
      return (PreflightItem(id: PreflightItem.stagingBuild, passed: true, detail: "verified, \(smoke), \(kind)"), staged)
    } catch {
      return (PreflightItem(id: PreflightItem.stagingBuild, passed: false, detail: String(describing: error)), nil)
    }
  }

  private func discardStaging(_ slug: Slug) {
    do {
      _ = try StagingArea(paths: env.paths).discard(slug: slug)
    } catch {
      log.error("cannot discard staging of \(slug.raw, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  /// `lsregister -u` for a bundle now in the backup folder, so no bundle id, `claude://` link or Open With resolves to
  /// it; a failure goes to updates.log and never fails the step.
  func forget(_ app: URL) async {
    let log = RedactingFileLog(url: LaunchServicesCleanup.updatesLog(env.paths))
    await env.registrar.unregisterLogged(app, context: "rebuild second", log: log)
  }

  private func afterSwap(_ step: String, backup: URL, _ body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch {
      throw RebuildError.afterSwap(step: step, backup: backup.path, message: String(describing: error))
    }
  }

  private func writeRequirement(_ report: BuildReport) throws {
    guard let requirement = report.designatedRequirement, !requirement.isEmpty else { throw BuilderError.noDesignatedRequirement }
    try FileManager.default.createDirectory(at: env.paths.signingDir, withIntermediateDirectories: true)
    try AtomicFile.write(Data((requirement + "\n").utf8), to: env.paths.requirementFile, permissions: 0o600)
  }

  /// `second` becomes `builtBy: "cmacc"` with no pending build (appended from the spec if it was missing).
  private func markRebuilt() async throws {
    let store = InstanceStore(paths: env.paths)
    let spec = env.spec
    let current = try await store.loadOrSeed().first { $0.slug == spec.slug }
      ?? Instance(slug: spec.slug, name: spec.displayName, kind: .clone, bundleId: spec.bundleId,
                  appPath: env.liveApp.path, profileDir: spec.profileDir.path, badge: spec.badge)
    _ = try await store.upsert(current.withBuild(builtBy: "cmacc", pendingBuild: nil))
  }
}

extension RebuildEnvironment {
  /// The real machine: `/Applications`, NSRunningApplication/lsappinfo/lock, the process tree, the default keychain
  /// search list (read-only), the builder pipeline and `lsregister`.
  public static func live(
    paths: Paths, runner: ProcessRunning, launcherBinary: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> RebuildEnvironment {
    let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let source = apps.appendingPathComponent("Claude.app", isDirectory: true)
    return RebuildEnvironment(
      applicationsDir: apps, paths: paths, running: RunningCheck(runner: runner), ancestry: AncestryCheck(),
      identity: SigningIdentityCheck(paths: paths, runner: runner),
      pipeline: InstanceBuildPipeline(paths: paths, runner: runner, launcherBinary: launcherBinary, clock: SystemClock()),
      registrar: Registrar(runner: runner, staging: StagingArea(paths: paths)), clock: SystemClock(),
      vendorUpdate: VendorUpdateCheck(runner: runner, sourceApp: source),
      sourceProbe: { try await SourceProbe(runner: runner).probe($0) },
      availableBytes: BuildEnvironment.volumeAvailableBytes, directorySize: DirectorySize.allocatedBytes,
      volume: Volume.identifier, hostAppVersion: environment["CLAUDE_CODE_DESKTOP_APP_VERSION"])
  }
}

/// Total allocated size of a directory tree (read-only enumeration).
enum DirectorySize {
  @Sendable static func allocatedBytes(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
      let values = try? file.resourceValues(forKeys: Set(keys))
      if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
    }
    return total
  }
}
