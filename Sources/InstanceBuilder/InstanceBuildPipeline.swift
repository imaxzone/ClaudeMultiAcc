import CoreGraphics
import Foundation
import IconRenderer
import os
import Support

/// Builds one clone in staging (steps 1–15 of the brief). Staged bundles are never launched, registered or
/// icon-queried (G12); on failure the staged dir is kept for inspection and the report says `verified=false`.
/// Clones get no Dock-tile plugin any more (usage limits are gone): no `dock-tile-plugin` step, no `NSDockTilePlugIn`.
public actor InstanceBuildPipeline {
  let paths: Paths
  let runner: ProcessRunning
  let launcherBinary: URL
  let clock: any Support.Clock
  let environment: BuildEnvironment
  /// The badge base: the registered icon of an official source app in `officialAppsRoot` (`BadgeStep`).
  let iconProvider: any AppIconProviding
  let officialAppsRoot: URL
  let staging: StagingArea
  let log = AppLog.logger("builder")

  /// The default: live environment (no ShipIt check for downloaded sources), NSWorkspace icons of the apps in
  /// /Applications.
  public init(paths: Paths, runner: ProcessRunning, launcherBinary: URL, clock: any Support.Clock) {
    self.init(
      paths: paths, runner: runner, launcherBinary: launcherBinary, clock: clock,
      environment: .live(runner: runner, downloads: paths.claudeSourcesDir))
  }

  public init(
    paths: Paths, runner: ProcessRunning, launcherBinary: URL, clock: any Support.Clock, environment: BuildEnvironment,
    iconProvider: any AppIconProviding = WorkspaceAppIconProvider(),
    officialAppsRoot: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
  ) {
    self.paths = paths
    self.runner = runner
    self.launcherBinary = launcherBinary
    self.clock = clock
    self.environment = environment
    self.iconProvider = iconProvider
    self.officialAppsRoot = officialAppsRoot
    self.staging = StagingArea(paths: paths)
  }

  /// Throws for refusals before anything is written (spec, running target for `.install`, ShipIt installing, disk space).
  /// Afterwards it always returns a report, also written to `<buildDir>/build-report.json`.
  public func build(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent) async throws -> BuildReport {
    let startedAt = clock.now
    var run = BuildRun(spec: spec, source: source, identity: identity, intent: intent, startedAt: startedAt)
    let started = ContinuousClock.now
    let preflight = try await preflight(spec: spec, source: source, intent: intent)
    run.extraSmoke.append(contentsOf: preflight.checks)
    run.record("preflight", ok: true, since: started, detail: preflight.target.detail)

    let buildDir = try staging.newBuildDir(slug: spec.slug, now: startedAt)
    run.buildDir = buildDir
    run.app = buildDir.appendingPathComponent("\(spec.displayName).app", isDirectory: true)
    log.info("building \(spec.slug.raw, privacy: .public) in \(buildDir.path, privacy: .public)")
    do {
      try await runSteps(&run)
      try? FileManager.default.removeItem(at: buildDir.appendingPathComponent("work"))
    } catch {
      run.failure = BuildFailure(step: run.currentStep, message: String(describing: error))
      log.error("build of \(spec.slug.raw, privacy: .public) failed at \(run.currentStep, privacy: .public): \(String(describing: error), privacy: .public)")
    }
    let report = run.report(finishedAt: clock.now)
    try writeReport(report, to: buildDir)
    return report
  }

  /// `vendor-update-pending` is recorded when ShipIt waits for the official app to quit (ShipIt only replaces the
  /// bundle after it terminated); `copy` and `recheck-source` ask again, and verify still guards the result.
  private func preflight(spec: CloneSpec, source: URL, intent: BuildIntent) async throws -> PreflightResult {
    try CloneSpec.checkDisplayName(spec.displayName)
    try CloneSpec.checkBundleId(spec.bundleId, slug: spec.slug)
    let running = await environment.running.isRunning(bundleId: spec.bundleId, profileDir: spec.profileDir)
    if running, intent == .install { throw BuilderError.targetRunning(spec.bundleId) }
    let vendor = await environment.vendorUpdate(source).state()
    if vendor == .installing { throw BuilderError.vendorUpdateActive }
    try FileManager.default.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
    let free = environment.availableBytes(paths.stagingDir) ?? 0
    guard free >= environment.minimumFreeBytes else { throw BuilderError.insufficientSpace(availableBytes: free) }
    let target = SmokeCheck("target-running", true, running ? "running" : "not running")
    let pending = vendor == .waitingForQuit
      ? SmokeCheck("vendor-update-pending", true, "update downloaded; ShipIt waits for Claude to quit") : nil
    return PreflightResult(target: target, vendorPending: pending)
  }

  private func runSteps(_ run: inout BuildRun) async throws {
    let (spec, app, source) = (run.spec, run.app, run.source)
    let sourceInfo = try await step("probe", &run) {
      let info = try await SourceProbe(runner: runner, policy: environment.sourcePolicy).probe(source)
      return (info, "\(info.version) team \(info.teamId)")
    }
    run.sourceVersion = sourceInfo.version
    try await step("copy", &run) {
      try await requireVendorNotInstalling(source)
      try await Cloner(runner: runner).copy(source: source, to: app)
      return ((), app.path)
    }
    try await step("patch-plist", &run) { try patchPlist(app: app, spec: spec); return ((), spec.bundleId) }
    try await step("clean", &run) { ((), try await Cloner(runner: runner).clean(app: app)) }
    let buildDir = run.buildDir
    let (snapshot, badgeBase) = try await step("snapshot-source", &run) {
      try await captureSourceAndBadgeBase(source, spec: spec, buildDir: buildDir, teamId: sourceInfo.teamId)
    }
    try await step("recheck-source", &run) { ((), try await recheckSource(source, against: sourceInfo)) }
    try await step("launcher", &run) {
      try LauncherInstaller().install(into: app, spec: spec, launcherBinary: launcherBinary, logsDir: paths.logsDir)
      return ((), launcherBinary.path)
    }
    // No updater step: `Contents/Frameworks` stays byte-identical to the vendor's (no ShipIt removal, no re-sign),
    // because the vendor helpers reject a Squirrel.framework with another Team ID. The clone's own updater stays
    // passive: it may download a release but cannot install it (other bundle id and designated requirement).
    try await customizeAndSign(&run, snapshot: snapshot, badgeBase: badgeBase)
  }

  var badgeStep: BadgeStep {
    BadgeStep(runner: runner, iconProvider: iconProvider, staging: staging, officialAppsRoot: officialAppsRoot)
  }

  /// `captureSource` plus, for a badged clone, the badge base image: both read before `recheck-source`.
  private func captureSourceAndBadgeBase(
    _ source: URL, spec: CloneSpec, buildDir: URL, teamId: String
  ) async throws -> ((SourceSnapshot, BadgeBase?), String) {
    let (snapshot, detail) = try await captureSource(source, buildDir: buildDir, teamId: teamId)
    guard spec.badge != nil else { return ((snapshot, nil), "\(detail), badge none") }
    let (image, base) = try await badgeStep.baseImage(source: source, workDir: buildDir.appendingPathComponent("work/badge"))
    return ((snapshot, BadgeBase(image: image, detail: base)), "\(detail), badge \(base)")
  }

  /// From here on nothing reads the live source: every source input comes from `snapshot` and `badgeBase`.
  /// The badge is baked into `electron.icns` before signing, so it is sealed with the bundle (R1).
  private func customizeAndSign(_ run: inout BuildRun, snapshot: SourceSnapshot, badgeBase: BadgeBase?) async throws {
    let (spec, app, buildDir, identity) = (run.spec, run.app, run.buildDir, run.identity)
    try await step("badge", &run) {
      guard let label = spec.badge, let badgeBase else { return ((), "no badge") }
      let work = buildDir.appendingPathComponent("work/badge")
      try await badgeStep.apply(app: app, base: badgeBase.image, label: label, workDir: work)
      return ((), badgeBase.detail)
    }
    let entitlements = try await step("entitlements", &run) {
      (snapshot.entitlements, "\(snapshot.entitlementsDetail) (read before recheck-source)")
    }
    try await step("sign", &run) {
      let lines = try await Signer(runner: runner).sign(
        app: app, spec: spec, entitlements: entitlements.url, identity: identity)
      return ((), "\(lines.count) codesign runs")
    }
    try await recordRequirement(&run)
    try await verifyAndSmoke(&run, entitlements: entitlements.data, reference: snapshot.facts)
  }

  private func recordRequirement(_ run: inout BuildRun) async throws {
    let app = run.app
    let identity = run.identity
    let requirement = try await step("requirement", &run) {
      let text = try await Signer(runner: runner).designatedRequirement(app: app)
      guard await isPermanentIdentity(identity) else { return ((text, String?.none), "report only") }
      try FileManager.default.createDirectory(at: paths.signingDir, withIntermediateDirectories: true)
      try AtomicFile.write(Data((text + "\n").utf8), to: paths.requirementFile, permissions: 0o600)
      return ((text, paths.requirementFile.path), "written to \(paths.requirementFile.lastPathComponent)")
    }
    run.designatedRequirement = requirement.0
    run.requirementFile = requirement.1
    run.extraSmoke.append(SmokeCheck("requirement-recorded", !requirement.0.isEmpty, requirement.1 ?? "in report"))
  }

  private func verifyAndSmoke(_ run: inout BuildRun, entitlements: Data, reference: SourceFacts) async throws {
    let (spec, app, extraSmoke) = (run.spec, run.app, run.extraSmoke)
    let result = try await step("verify", &run) {
      let result = try await Verifier(runner: runner, helperTeamId: environment.sourcePolicy.expectedTeamId)
        .verify(app: app, spec: spec, expectedEntitlements: entitlements)
      return (result, "\(result.checks.filter(\.passed).count)/\(result.checks.count) passed")
    }
    run.verification = result.checks
    guard result.passed else { throw BuilderError.verificationFailed(result.checks.filter { !$0.passed }.map(\.name)) }
    let checks = try await step("smoke", &run) {
      let checks = try await StaticSmoke(runner: runner).run(app: app, reference: reference, spec: spec) + extraSmoke
      return (checks, "\(checks.filter(\.passed).count)/\(checks.count) passed")
    }
    run.smoke = checks
    let failed = checks.filter { !$0.passed }.map(\.name)
    guard failed.isEmpty else { throw BuilderError.smokeFailed(failed) }
    run.verified = true
  }
}

/// The badge base image read from the source before `recheck-source`, and the detail line naming it.
struct BadgeBase {
  let image: CGImage
  let detail: String
}
