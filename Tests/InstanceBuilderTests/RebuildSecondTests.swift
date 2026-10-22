import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct RebuildSecondTests {
  struct Knobs {
    var running = false
    var ancestors = ["/bin/zsh", "/Applications/Claude.app/Contents/MacOS/Claude"]
    var hostVersion: String?
    var identity = true
    var keychainSHA1: String? = testSHA1
    var free: Int64 = 50_000_000_000
    var vendor: VendorUpdateState = .idle
    var sourceError: BuilderError?
    var verified = true
    var backupVolume = "vol-1"
    var profile = true
    var launcherProfile: String?
    /// Flips the running check to "running" from this query on (1 = the preflight's not-running item).
    var runningFromCall: Int?
    var unregisterFails = false
  }

  struct Fixture {
    let root: URL
    let paths: Paths
    let env: RebuildEnvironment
    let log: EventLog
    /// `instances.json` as the fixture wrote it.
    let list: Data
  }

  static let now = Date(timeIntervalSince1970: 1_790_000_000)

  func fixture(_ k: Knobs = Knobs(), _ name: String = #function) throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    try paths.ensureDataDirs()
    let list = try Self.writeLegacySecondList(paths, home: root)
    let apps = root.appendingPathComponent("Applications", isDirectory: true)
    try MiniBundle.write(Data("<plist>old</plist>".utf8), apps.appendingPathComponent("Claude 2nd.app/Contents/Info.plist"))
    try MiniBundle.write(Data("old".utf8), apps.appendingPathComponent("Claude 2nd.app/Contents/MacOS/Claude"), mode: 0o755)
    if k.profile {
      try FileManager.default.createDirectory(at: CloneSpec.second(home: root).profileDir, withIntermediateDirectories: true)
    }
    if k.identity { try installIdentity(paths) }
    let log = EventLog()
    let backupVolume = k.backupVolume
    let sourceError = k.sourceError
    let env = RebuildEnvironment(
      applicationsDir: apps, paths: paths,
      running: k.runningFromCall.map { FlipRunningCheck(runningFromCall: $0) as any RunningChecking }
        ?? FakeRunningCheck(running: k.running),
      ancestry: AncestryCheck(provider: { [k, apps] in
        k.ancestors.map { $0.replacingOccurrences(of: "{LIVE}", with: apps.appendingPathComponent("Claude 2nd.app").path) }
      }),
      identity: SigningIdentityCheck(paths: paths, runner: securityRunner(listing: k.keychainSHA1)),
      pipeline: FakeCloneBuilder(paths: paths, log: log, verified: k.verified, launcherProfile: k.launcherProfile),
      registrar: FakeRegistrar(log: log, unregisterFails: k.unregisterFails), clock: FixedClock(now: Self.now),
      vendorUpdate: FakeVendorUpdateCheck(state: k.vendor),
      sourceProbe: { url in
        if let sourceError { throw sourceError }
        return SourceInfo(url: url, bundleId: CloneSpec.vendorBundleId, version: "2.0.0", teamId: "Q6L2SF6YDW",
                          mainExecutableSHA256: "00")
      },
      availableBytes: { [k] _ in k.free }, directorySize: { _ in 700_000_000 },
      volume: { url in url.path.contains("/data/backup") ? backupVolume : "vol-1" },
      hostAppVersion: k.hostVersion, timeZone: .gmt)
    return Fixture(root: root, paths: paths, env: env, log: log, list: list)
  }

  private struct ListFile: Encodable {
    let schemaVersion = 1
    let instances: [Instance]
  }

  /// Writes the seeds (only `main`) plus the legacy-script `second`, with synthetic UUIDs; returns the file's bytes.
  static func writeLegacySecondList(_ paths: Paths, home: URL) throws -> Data {
    let spec = CloneSpec.second(home: home)
    let second = Instance(
      slug: spec.slug, name: spec.displayName, kind: .clone, bundleId: spec.bundleId,
      appPath: "/Applications/Claude 2nd.app", profileDir: spec.profileDir.path,
      accountUuid: "aaaaaaaa-0000-4000-8000-000000000002", orgUuid: "00000000-0000-4000-8000-000000000002",
      badge: "2nd", builtBy: "legacy-script")
    let data = try JSONCoding.encoder.encode(ListFile(instances: InstanceSeeds.seeds(home: home) + [second]))
    try data.write(to: paths.instancesFile)
    return data
  }

  private func result(_ items: [PreflightItem], _ id: String) -> PreflightItem? {
    items.first { $0.id == id }
  }

  @Test func everyItemPassesAndTheStagingIsDiscarded() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let items = await RebuildSecond(env: f.env).check(keepStaging: false)
    #expect(items.map(\.id) == PreflightItem.order)
    let failed = items.filter { !$0.passed }.map(\.line)
    #expect(failed.isEmpty, "\(failed)")
    #expect(f.log.all == ["build(stagingOnly,certificate,second)"])
    #expect(try StagingArea(paths: f.paths).builds(slug: testSlug("second")).isEmpty)
    // The list marks Claude 2nd as built by the legacy script: its backup carries the protected `legacy-` prefix.
    #expect(result(items, PreflightItem.backupPlan)?.detail.hasSuffix("/data/backup/legacy-Claude 2nd.app.20260921-141320") == true)
    #expect(items[1].line == "PASS not-running — not running")
  }

  @Test(arguments: [
    (VendorUpdateState.idle, true, "ShipIt idle"),
    (.waitingForQuit, true, "update pending — ShipIt waits for Claude to quit (safe to build)"),
    (.installing, false, "Claude is being updated right now — retry in a minute"),
  ])
  func vendorIdleItemFollowsTheUpdateState(state: VendorUpdateState, passed: Bool, detail: String) async {
    let item = await PreflightCheck.vendorIdle(FakeVendorUpdateCheck(state: state))
    #expect(item.id == PreflightItem.vendorIdle && item.passed == passed && item.detail == detail)
  }

  @Test func keepStagingKeepsTheBuild() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    _ = await RebuildSecond(env: f.env).check(keepStaging: true)
    #expect(try StagingArea(paths: f.paths).builds(slug: testSlug("second")).count == 1)
  }

  /// One knob per row → exactly that item fails.
  @Test(arguments: [
    ("running", PreflightItem.notRunning), ("hosted", PreflightItem.notHostedInside),
    ("no-identity", PreflightItem.identityPresent), ("keychain-mismatch", PreflightItem.identityPresent),
    ("low-disk", PreflightItem.diskSpace), ("shipit", PreflightItem.vendorIdle), ("bad-source", PreflightItem.sourceOK),
    ("unverified", PreflightItem.stagingBuild), ("other-volume", PreflightItem.backupPlan),
    ("no-profile", PreflightItem.profileIntact), ("launcher-mismatch", PreflightItem.profileIntact),
  ])
  func eachKnobFailsItsItem(knob: String, failing: String) async throws {
    var k = Knobs()
    switch knob {
    case "running": k.running = true
    case "hosted": k.ancestors = ["/bin/zsh", "{LIVE}/Contents/MacOS/Claude.real"]
    case "no-identity": k.identity = false
    case "keychain-mismatch": k.keychainSHA1 = String(repeating: "CD", count: 20)
    case "low-disk": k.free = 2_500_000_000
    case "shipit": k.vendor = .installing
    case "bad-source": k.sourceError = .unexpectedTeamId(expected: "Q6L2SF6YDW", found: "XXXX")
    case "unverified": k.verified = false
    case "other-volume": k.backupVolume = "vol-2"
    case "no-profile": k.profile = false
    default: k.launcherProfile = "/elsewhere"
    }
    let f = try fixture(k, "knob-\(knob)")
    defer { try? FileManager.default.removeItem(at: f.root) }
    let items = await RebuildSecond(env: f.env).check(keepStaging: false)
    #expect(items.filter { !$0.passed }.map(\.id) == [failing], "\(knob): \(items.map(\.line))")
  }

  @Test func withoutIdentityTheStagingBuildIsAdhoc() async throws {
    var k = Knobs()
    k.identity = false
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let items = await RebuildSecond(env: f.env).check(keepStaging: false)
    #expect(f.log.all == ["build(stagingOnly,adhoc,second)"])
    let build = try #require(result(items, PreflightItem.stagingBuild))
    #expect(build.passed && build.detail.contains("adhoc — apply needs the permanent identity"))
  }

  @Test func hostingDetailNamesTheHostApp() async throws {
    var k = Knobs()
    k.hostVersion = "1.2.3"
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let items = await RebuildSecond(env: f.env).check(keepStaging: false)
    let hosted = try #require(result(items, PreflightItem.notHostedInside))
    #expect(hosted.passed)
    #expect(hosted.detail.contains("session hosted by /Applications/Claude.app (CLAUDE_CODE_DESKTOP_APP_VERSION=1.2.3)"))
  }

  private func marker(_ app: URL) -> String? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Claude"))).map { String(decoding: $0, as: UTF8.self) }
  }

  @Test func applyRunsCheckBuildSwapRegisterRequirementStoreInOrder() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let result = try await RebuildSecond(env: f.env).apply()
    #expect(result.steps == ["check", "build", "swap", "register", "requirement", "store"])
    #expect(f.log.all == [
      "build(stagingOnly,certificate,second)", "build(install,certificate,second)", "register(Claude 2nd.app,new)",
      "unregister(backup/legacy-Claude 2nd.app.20260921-141320)",
    ])
    #expect(marker(f.env.liveApp) == "new")
    // R1: the rebuilt bundle carries its badge in `electron.icns`; no Finder custom icon is written after the swap.
    #expect(!CustomIconCheck.inspect(f.env.liveApp).present)
    #expect(marker(result.backup) == "old")
    #expect(result.backup.path == f.paths.backupDir.appendingPathComponent("legacy-Claude 2nd.app.20260921-141320").path)
    #expect(FileManager.default.fileExists(atPath: result.backup.appendingPathComponent("Contents/Info.plist.disabled").path))
    let requirement = try String(contentsOf: f.paths.requirementFile, encoding: .utf8)
    #expect(requirement.hasPrefix("identifier \"com.anthropic.claudefordesktop2\""))
    let second = try #require(try await InstanceStore(paths: f.paths).load().first { $0.slug.raw == "second" })
    #expect(second.builtBy == "cmacc" && second.pendingBuild == nil)
    #expect(second.accountUuid == "aaaaaaaa-0000-4000-8000-000000000002")
    #expect(result.rollbackCommand == "cmacc instance rollback second \(result.backup.path)")
  }

  /// A clone already built by cmacc gets a plain backup name (prunable like every later backup).
  @Test func applyOfACmaccBuiltCloneUsesThePlainBackupName() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = InstanceStore(paths: f.paths)
    let seeded = try await store.load().map { $0.slug.raw == "second" ? $0.withBuild(builtBy: "cmacc", pendingBuild: nil) : $0 }
    try await store.save(seeded)
    let result = try await RebuildSecond(env: f.env).apply()
    #expect(result.backup.lastPathComponent == "Claude 2nd.app.20260921-141320")
  }

  /// An unreadable instances.json must never cost the legacy backup its protection: fail closed to `legacy-`.
  @Test func unreadableStoreStillProtectsTheBackup() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try Data("{ not json".utf8).write(to: f.paths.instancesFile)
    let rebuild = RebuildSecond(env: f.env)
    #expect(await rebuild.backupPrefix() == "legacy-")
    let items = await rebuild.check(keepStaging: false)
    #expect(result(items, PreflightItem.backupPlan)?.detail.hasSuffix("/data/backup/legacy-Claude 2nd.app.20260921-141320") == true)
  }

  @Test func applyRefusesWhenAnyCheckFailsAndChangesNothing() async throws {
    var k = Knobs()
    k.running = true
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    await #expect(throws: RebuildError.preflightFailed([PreflightItem.notRunning])) {
      _ = try await RebuildSecond(env: f.env).apply()
    }
    #expect(f.log.all == ["build(stagingOnly,certificate,second)"])
    #expect(marker(f.env.liveApp) == "old")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path).isEmpty)
    #expect(try Data(contentsOf: f.paths.instancesFile) == f.list)
  }

  /// Claude 2nd launched during the minutes-long builds: the re-check right before the swap refuses, the live
  /// bundle stays untouched and the staged install build is kept.
  @Test func applyRechecksRunningRightBeforeTheSwap() async throws {
    var k = Knobs()
    k.runningFromCall = 2
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    await #expect(throws: RebuildError.targetRunning(CloneSpec.legacySecondBundleId)) {
      _ = try await RebuildSecond(env: f.env).apply()
    }
    #expect(f.log.all == ["build(stagingOnly,certificate,second)", "build(install,certificate,second)"])
    #expect(marker(f.env.liveApp) == "old")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path).isEmpty)
    #expect(try StagingArea(paths: f.paths).builds(slug: testSlug("second")).count == 1)
    #expect(try Data(contentsOf: f.paths.instancesFile) == f.list)
  }

  /// Launched between the swap and the registration: stop before `lsregister`, keep the backup for rollback.
  @Test func applyRechecksRunningBeforeRegister() async throws {
    var k = Knobs()
    k.runningFromCall = 3
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    do {
      _ = try await RebuildSecond(env: f.env).apply()
      Issue.record("apply must throw")
    } catch let RebuildError.afterSwap(step, backup, _) {
      #expect(step == "register")
      #expect(marker(URL(fileURLWithPath: backup)) == "old")
    }
    #expect(!f.log.all.contains { $0.hasPrefix("register") })
    #expect(try Data(contentsOf: f.paths.instancesFile) == f.list)
  }

  @Test func rollbackRestoresTheBackupAndKeepsTheFailedBuildAside() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let rebuild = RebuildSecond(env: f.env)
    let result = try await rebuild.apply()
    // Same fixed clock: rollback's failed-<ts> dir must not collide with the backup name.
    try await rebuild.rollback(backup: result.backup)
    #expect(marker(f.env.liveApp) == "old")
    #expect(FileManager.default.fileExists(atPath: f.env.liveApp.appendingPathComponent("Contents/Info.plist").path))
    #expect(!FileManager.default.fileExists(atPath: result.backup.path))
    let failed = f.paths.backupDir.appendingPathComponent("failed-20260921-141320/Claude 2nd.app")
    #expect(marker(failed) == "new")
    #expect(FileManager.default.fileExists(atPath: failed.appendingPathComponent("Contents/Info.plist.disabled").path))
    // LaunchServices forgets the backup before it moves back and the failed build once the restored app is registered.
    #expect(f.log.all.suffix(3) == [
      "unregister(backup/legacy-Claude 2nd.app.20260921-141320)", "register(Claude 2nd.app,old)",
      "unregister(failed-20260921-141320/Claude 2nd.app)",
    ])
  }

  @Test func rollbackRefusesWhileRunningOrForForeignPaths() async throws {
    var k = Knobs()
    k.running = true
    let f = try fixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    let backup = f.paths.backupDir.appendingPathComponent("Claude 2nd.app.20260921-141320")
    await #expect(throws: RebuildError.runningDuringRollback(CloneSpec.legacySecondBundleId, backup: backup.path)) {
      try await RebuildSecond(env: f.env).rollback(backup: backup)
    }
    let idle = try fixture(Knobs(), "rollback-idle")
    defer { try? FileManager.default.removeItem(at: idle.root) }
    let foreign = idle.root.appendingPathComponent("Applications/Claude.app")
    await #expect(throws: RebuildError.backupInvalid(foreign.path)) {
      try await RebuildSecond(env: idle.env).rollback(backup: foreign)
    }
    #expect(marker(idle.env.liveApp) == "old")
    #expect(idle.log.all.isEmpty)
  }
}
