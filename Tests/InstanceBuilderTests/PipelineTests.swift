import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

@Suite struct PipelineTests {
  struct Fixture {
    let root: URL
    let paths: Paths
    let source: URL
    let launcher: URL
    let spec: CloneSpec
  }

  private func makeFixture(_ name: String = #function) throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let source = try MiniBundle.makeSource(in: root.appendingPathComponent("Applications"))
    let launcher = root.appendingPathComponent("CloneLauncher")
    try MiniBundle.write(MiniBundle.machOBytes, launcher, mode: 0o755)
    let spec = CloneSpec.newClone(slug: testSlug("stagetest"), displayName: "Claude Stagetest", home: root)
      .with(badge: "T")
    return Fixture(root: root, paths: paths, source: source, launcher: launcher, spec: spec)
  }

  private func environment(
    _ f: Fixture, running: Bool = false, vendor: VendorUpdateState = .idle, freeBytes: Int64 = 50_000_000_000
  ) -> BuildEnvironment {
    environment(f, running: running, vendorCheck: FakeVendorUpdateCheck(state: vendor), freeBytes: freeBytes)
  }

  private func environment(
    _ f: Fixture, running: Bool = false, vendorCheck: any VendorUpdateChecking, freeBytes: Int64 = 50_000_000_000
  ) -> BuildEnvironment {
    BuildEnvironment(
      running: FakeRunningCheck(running: running), vendorUpdate: { _ in vendorCheck },
      availableBytes: { _ in freeBytes }, sourcePolicy: .vendor)
  }

  /// The fixture's `Applications` folder counts as official; `icons` answers nil unless a test passes another.
  private func pipeline(
    _ f: Fixture, runner: ScriptedRunner, env: BuildEnvironment, icons: FakeIconProvider = FakeIconProvider(side: nil)
  ) -> InstanceBuildPipeline {
    InstanceBuildPipeline(
      paths: f.paths, runner: runner, launcherBinary: f.launcher,
      clock: FixedClock(now: Date(timeIntervalSince1970: 1_790_000_000)), environment: env, iconProvider: icons,
      officialAppsRoot: f.root.appendingPathComponent("Applications"))
  }

  @Test func successfulBuildRunsEveryStepInOrderAndWritesReport() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    #expect(report.steps.map(\.name) == [
      "preflight", "probe", "copy", "patch-plist", "clean", "snapshot-source", "recheck-source", "launcher", "badge",
      "entitlements", "sign", "requirement", "verify", "smoke",
    ])
    #expect(report.steps.allSatisfy { $0.ok })
    #expect(report.stagedPath.hasSuffix("/stagetest-") == false)
    #expect(report.stagedPath.hasSuffix(".noindex/Claude Stagetest.app"))
    #expect(report.identityKind == "adhoc")
    #expect(report.sourceVersion == "2.7032.0")
    #expect(report.designatedRequirement?.contains("com.imaxzone.claude.stagetest") == true)
    let smokeNames = report.smoke.map(\.name)
    #expect(smokeNames.contains("target-running") && smokeNames.contains("icns-badged")
      && smokeNames.contains("requirement-recorded") && !smokeNames.contains("plugin-declared"))
    #expect(report.smoke.first { $0.name == "target-running" }?.detail == "not running")
    #expect(report.steps.first { $0.name == "badge" }?.detail == "base=electron.icns 1024px")

    let staged = URL(fileURLWithPath: report.stagedPath)
    let reportFile = staged.deletingLastPathComponent().appendingPathComponent("build-report.json")
    let decoded = try JSONCoding.decoder.decode(BuildReport.self, from: Data(contentsOf: reportFile))
    #expect(decoded.verified && decoded.slug == "stagetest")
    #expect(!FileManager.default.fileExists(atPath: f.paths.requirementFile.path))
    #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().appendingPathComponent("work").path))

    let lines = runner.commandLines
    let firstSign = try #require(lines.firstIndex { $0.contains("--force") })
    let entitlementsRead = try #require(lines.firstIndex { $0.contains("--entitlements") && $0.last == f.source.path })
    let copyIndex = try #require(lines.firstIndex { $0.first == "cp" })
    #expect(copyIndex < entitlementsRead && entitlementsRead < firstSign)
    #expect(lines[copyIndex] == ["cp", "-Rc", f.source.path, report.stagedPath])
  }

  @Test func installIntentRefusesRunningTargetBeforeTouchingDisk() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    await #expect(throws: BuilderError.targetRunning("com.imaxzone.claude.stagetest")) {
      _ = try await pipeline(f, runner: runner, env: environment(f, running: true))
        .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .install)
    }
    #expect(runner.recorded.isEmpty)
    #expect(try StagingArea(paths: f.paths).builds(slug: f.spec.slug).isEmpty)
  }

  @Test func stagingOnlyRecordsRunningTargetAndContinues() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f, running: true))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified)
    let check = try #require(report.smoke.first { $0.name == "target-running" })
    #expect(check.passed && check.detail == "running")
  }

  @Test func installingShipItRefusesBothIntents() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    for intent in [BuildIntent.stagingOnly, .install] {
      let runner = try PipelineFakeRunner.make(spec: f.spec)
      await #expect(throws: BuilderError.vendorUpdateActive) {
        _ = try await pipeline(f, runner: runner, env: environment(f, vendor: .installing))
          .build(spec: f.spec, source: f.source, identity: .adhoc, intent: intent)
      }
      #expect(runner.recorded.isEmpty)
      #expect(try StagingArea(paths: f.paths).builds(slug: f.spec.slug).isEmpty)
    }
  }

  /// ShipIt waiting for the official app to quit touches nothing: the build proceeds and notes the pending update.
  @Test func pendingVendorUpdateBuildsAndIsRecorded() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f, vendor: .waitingForQuit))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    let check = try #require(report.smoke.first { $0.name == "vendor-update-pending" })
    #expect(check.passed && check.detail == "update downloaded; ShipIt waits for Claude to quit")
  }

  @Test func idleVendorRecordsNoPendingUpdate() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(!report.smoke.contains { $0.name == "vendor-update-pending" })
  }

  @Test func lowDiskSpaceRefuses() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    await #expect(throws: BuilderError.insufficientSpace(availableBytes: 1_000)) {
      _ = try await pipeline(f, runner: runner, env: environment(f, freeBytes: 1_000))
        .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    }
  }

  @Test func invalidDisplayNameRefuses() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let bad = CloneSpec.newClone(slug: testSlug("stagetest"), displayName: "../Evil", home: f.root)
    await #expect(throws: BuilderError.invalidDisplayName("../Evil")) {
      _ = try await pipeline(f, runner: try PipelineFakeRunner.make(spec: bad), env: environment(f))
        .build(spec: bad, source: f.source, identity: .adhoc, intent: .stagingOnly)
    }
  }

  @Test func sourceChangeDuringCopyAbortsAndKeepsStagedDir() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var options = PipelineFakeRunner.Options()
    options.mutateSourceOnCopy = true
    let runner = try PipelineFakeRunner.make(spec: f.spec, options: options)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(!report.verified)
    #expect(report.failure?.step == "recheck-source")
    #expect(report.failure?.message == BuilderError.sourceChangedDuringCopy.description)
    #expect(report.steps.last?.name == "recheck-source" && report.steps.last?.ok == false)
    #expect(!runner.commandLines.contains { $0.contains("--force") })
    #expect(FileManager.default.fileExists(atPath: report.stagedPath))
    let reportFile = URL(fileURLWithPath: report.stagedPath).deletingLastPathComponent().appendingPathComponent("build-report.json")
    #expect(FileManager.default.fileExists(atPath: reportFile.path))
  }

  private func buildStops(
    _ f: Fixture, vendorCheck: any VendorUpdateChecking, options: PipelineFakeRunner.Options = .init()
  ) async throws -> (BuildReport, ScriptedRunner) {
    let runner = try PipelineFakeRunner.make(spec: f.spec, options: options)
    let report = try await pipeline(f, runner: runner, env: environment(f, vendorCheck: vendorCheck))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(!report.verified)
    #expect(!runner.commandLines.contains { $0.contains("--force") }, "nothing may be signed")
    return (report, runner)
  }

  /// Claude quit after preflight and ShipIt started installing: no copy is made.
  @Test func shipItInstallingBeforeCopyStopsAtCopy() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (report, runner) = try await buildStops(f, vendorCheck: SequencedVendorCheck([.waitingForQuit, .installing]))
    #expect(report.failure?.step == "copy")
    #expect(report.failure?.message == BuilderError.vendorUpdateActive.description)
    #expect(!runner.commandLines.contains { $0.first == "cp" })
  }

  @Test func shipItInstallingAfterCopyStopsAtRecheck() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (report, _) = try await buildStops(
      f, vendorCheck: SequencedVendorCheck([.waitingForQuit, .waitingForQuit, .installing]))
    #expect(report.failure?.step == "recheck-source")
    #expect(report.failure?.message == BuilderError.vendorUpdateActive.description)
  }

  @Test func sourceVersionChangeDuringCopyStopsAtRecheck() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var options = PipelineFakeRunner.Options()
    options.bumpSourceVersionOnCopy = true
    let (report, _) = try await buildStops(f, vendorCheck: FakeVendorUpdateCheck(state: .waitingForQuit), options: options)
    #expect(report.failure?.step == "recheck-source")
    #expect(report.failure?.message == BuilderError.sourceChangedDuringCopy.description)
  }

  /// After `recheck-source` (the third vendor query) no step reads the live source any more.
  @Test func noStepAfterRecheckReadsTheSource() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let mark = Mutex<Int?>(nil)
    let doomed = ["Contents/Resources/electron.icns", "Contents/Frameworks"].map { f.source.appendingPathComponent($0) }
    let vendor = SequencedVendorCheck([.idle]) { [runner] call in
      guard call == 3 else { return }
      mark.withLock { $0 = runner.recorded.count }
      // The source vanishing after the guard must not matter to later steps.
      for url in doomed { try? FileManager.default.removeItem(at: url) }
    }
    let report = try await pipeline(f, runner: runner, env: environment(f, vendorCheck: vendor))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    #expect(vendor.callCount == 3)
    let after = try #require(mark.withLock { $0 })
    let late = runner.recorded.dropFirst(after).filter { $0.arguments.contains { $0.hasPrefix(f.source.path) } }
    #expect(late.isEmpty, "\(late.map(\.arguments))")
  }

  @Test func failedVerificationStopsBeforeSmoke() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var options = PipelineFakeRunner.Options()
    options.verifyExit = 3
    let report = try await pipeline(f, runner: try PipelineFakeRunner.make(spec: f.spec, options: options), env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(!report.verified)
    #expect(report.failure?.step == "verify")
    #expect(report.verification.contains { $0.name == "codesign-verify-deep-strict" && !$0.passed })
    #expect(!report.steps.contains { $0.name == "smoke" })
  }

  @Test func permanentIdentityRecordsRequirementFile() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let sha = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
    try await SettingsStore(file: f.paths.settingsFile).update { settings in
      var copy = settings
      copy.builder.signingIdentitySHA1 = sha.lowercased()
      return copy
    }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .certificate(sha1: sha, keychain: nil), intent: .stagingOnly)
    #expect(report.verified)
    let recorded = try String(contentsOf: f.paths.requirementFile, encoding: .utf8)
    #expect(recorded.contains("com.imaxzone.claude.stagetest"))
    #expect(report.requirementFile == f.paths.requirementFile.path)
  }

  /// Usage limits are gone: clones get no Dock-tile plugin, no `NSDockTilePlugIn` and no `Contents/PlugIns`.
  @Test func noDockTilePluginIsInstalledDeclaredOrSigned() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    #expect(!report.steps.contains { $0.name == "dock-tile-plugin" })
    let staged = URL(fileURLWithPath: report.stagedPath)
    #expect(try plistDict(try Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")))["NSDockTilePlugIn"] == nil)
    #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/PlugIns").path))
    #expect(!runner.commandLines.contains { $0.contains { $0.contains("PlugIns") } })
  }

  /// R1: the badge is baked into `electron.icns` before signing (so it is sealed), `CFBundleIconName` goes and the
  /// vendor's `Assets.car` (runtime images Claude loads) stays byte-identical; no Finder custom icon is written.
  @Test func badgeIsBakedIntoElectronIcnsBeforeSigning() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let assets = "Contents/Resources/Assets.car"
    try Data("vendor-assets".utf8).write(to: f.source.appendingPathComponent(assets))
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    let lines = runner.commandLines
    let written = try #require(lines.firstIndex { $0.prefix(3) == ["iconutil", "-c", "icns"] })
    let firstSign = try #require(lines.firstIndex { $0.contains("--force") })
    #expect(written < firstSign)
    let staged = URL(fileURLWithPath: report.stagedPath)
    #expect(try Data(contentsOf: staged.appendingPathComponent("Contents/Resources/electron.icns")) == Data(fakeBadgedIcns.utf8))
    #expect(try Data(contentsOf: staged.appendingPathComponent(assets)) == Data("vendor-assets".utf8))
    let info = try plistDict(try Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")))
    #expect(info["CFBundleIconName"] == nil && info["CFBundleIconFile"] as? String == "electron.icns")
    #expect(report.smoke.first { $0.name == "icns-badged" }?.passed == true)
    #expect(report.smoke.first { $0.name == "no-icon-name" }?.passed == true)
    #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("Icon\r").path))
  }

  @Test func noBadgeSkipsTheBadgeStep() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let plain = f.spec.with(badge: nil)
    let runner = try PipelineFakeRunner.make(spec: plain)
    let icons = FakeIconProvider(side: 1024)
    let report = try await pipeline(f, runner: runner, env: environment(f), icons: icons)
      .build(spec: plain, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified)
    #expect(report.steps.first { $0.name == "badge" }?.detail == "no badge")
    #expect(!runner.commandLines.contains { $0.first == "iconutil" })
    #expect(icons.requested.isEmpty)
    let icns = "Contents/Resources/electron.icns"
    let staged = URL(fileURLWithPath: report.stagedPath)
    #expect(try Data(contentsOf: staged.appendingPathComponent(icns)) == Data(contentsOf: f.source.appendingPathComponent(icns)))
    #expect(report.smoke.first { $0.name == "icns-badged" }?.detail.hasPrefix("skipped") == true)
  }

  /// The official app's registered icon is the base, queried once and before `recheck-source` (the third vendor
  /// query); the staged bundle is never icon-queried (G12).
  @Test func workspaceIconOfTheOfficialSourceIsReadBeforeRecheck() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let icons = FakeIconProvider(side: 1024)
    let queriedBeforeRecheck = Mutex<[String]?>(nil)
    let vendor = SequencedVendorCheck([.idle]) { call in
      if call == 3 { queriedBeforeRecheck.withLock { $0 = icons.requested } }
    }
    let report = try await pipeline(f, runner: runner, env: environment(f, vendorCheck: vendor), icons: icons)
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    #expect(queriedBeforeRecheck.withLock { $0 } == [f.source.path])
    #expect(icons.requested == [f.source.path])
    #expect(report.steps.first { $0.name == "badge" }?.detail == "base=workspace-icon 1024px")
    #expect(!runner.commandLines.contains { $0.prefix(3) == ["iconutil", "-c", "iconset"] })
  }

  /// The vendor helpers load `Contents/Frameworks` with library validation: the clone keeps that folder
  /// byte-identical to the source (ShipIt included) and never re-signs anything in it.
  @Test func vendorFrameworksAreNeverModifiedOrResigned() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let runner = try PipelineFakeRunner.make(spec: f.spec)
    let report = try await pipeline(f, runner: runner, env: environment(f))
      .build(spec: f.spec, source: f.source, identity: .adhoc, intent: .stagingOnly)
    #expect(report.verified, "\(report.failure.map { "\($0.step): \($0.message)" } ?? "")")
    #expect(!report.steps.contains { $0.name == "neutralize-updater" })
    let signed = runner.commandLines.filter { $0.contains("--force") }.compactMap(\.last)
    #expect(signed.count == 2 && !signed.contains { $0.contains("/Contents/Frameworks") }, "\(signed)")
    let staged = URL(fileURLWithPath: report.stagedPath)
    let frameworks = "Contents/Frameworks"
    let stagedTree = try MiniBundle.treeDigest(staged.appendingPathComponent(frameworks))
    #expect(!stagedTree.isEmpty)
    #expect(stagedTree == (try MiniBundle.treeDigest(f.source.appendingPathComponent(frameworks))))
    #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent(VendorFrameworksCheck.shipItPath).path))
    #expect(report.smoke.first { $0.name == "vendor-frameworks-intact" }
      == SmokeCheck(name: "vendor-frameworks-intact", passed: true, detail: "2 bundles signed by Q6L2SF6YDW, ShipIt present"))
  }
}
