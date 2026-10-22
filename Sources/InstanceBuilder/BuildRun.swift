import Foundation
import Support

/// Mutable state of one pipeline run; lives only inside `InstanceBuildPipeline.build`.
struct BuildRun {
  let spec: CloneSpec
  let source: URL
  let identity: SigningIdentity
  let intent: BuildIntent
  let startedAt: Date
  var buildDir = URL(fileURLWithPath: "/")
  var app = URL(fileURLWithPath: "/")
  var sourceVersion = "unknown"
  var steps: [StepRecord] = []
  var currentStep = "preflight"
  var verification: [SmokeCheck] = []
  var smoke: [SmokeCheck] = []
  var extraSmoke: [SmokeCheck] = []
  var designatedRequirement: String?
  var requirementFile: String?
  var failure: BuildFailure?
  var verified = false

  init(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent, startedAt: Date) {
    self.spec = spec
    self.source = source
    self.identity = identity
    self.intent = intent
    self.startedAt = startedAt
  }

  mutating func record(_ name: String, ok: Bool, since start: ContinuousClock.Instant, detail: String) {
    let elapsed = ContinuousClock.now - start
    let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    steps.append(StepRecord(name: name, ok: ok, ms: ms, detail: detail))
  }

  func report(finishedAt: Date) -> BuildReport {
    BuildReport(
      slug: spec.slug.raw, bundleId: spec.bundleId, displayName: spec.displayName, badge: spec.badge,
      intent: intent, sourcePath: source.path, sourceVersion: sourceVersion,
      stagedPath: app.path, identityKind: identity.kind, steps: steps, verification: verification,
      smoke: smoke.isEmpty ? extraSmoke : smoke, designatedRequirement: designatedRequirement,
      requirementFile: requirementFile, failure: failure, verified: verified && failure == nil,
      startedAt: startedAt, finishedAt: finishedAt)
  }
}

extension InstanceBuildPipeline {
  /// Runs one named step, timing it and recording success or failure (then rethrowing).
  func step<T>(_ name: String, _ run: inout BuildRun, _ body: () async throws -> (T, String)) async throws -> T {
    run.currentStep = name
    let start = ContinuousClock.now
    do {
      let (value, detail) = try await body()
      run.record(name, ok: true, since: start, detail: detail)
      return value
    } catch {
      run.record(name, ok: false, since: start, detail: String(describing: error))
      throw error
    }
  }

  func patchPlist(app: URL, spec: CloneSpec) throws {
    let url = app.appendingPathComponent("Contents/Info.plist")
    let patched = try PlistPatcher.patch(try Data(contentsOf: url), spec: spec)
    try AtomicFile.write(patched, to: url, permissions: 0o644)
  }

  /// Step 11: the source's entitlements through `EntitlementsFilter`, written to `<buildDir>/entitlements.plist`.
  func filteredEntitlements(source: URL, buildDir: URL) async throws -> ((url: URL, data: Data), String) {
    let result = try await runner.runChecked(
      BuilderTool.codesign, ["-d", "--entitlements", "-", "--xml", source.path], timeout: BuilderTool.shortTimeout)
    let filtered = try EntitlementsFilter.filter(result.stdout)
    let url = buildDir.appendingPathComponent("entitlements.plist")
    try filtered.write(to: url)
    let count = (try? EntitlementsFilter.decode(filtered).count) ?? 0
    return ((url, filtered), "\(count) keys")
  }

  func isPermanentIdentity(_ identity: SigningIdentity) async -> Bool {
    guard case .certificate(let sha1, _) = identity else { return false }
    let settings = await SettingsStore(file: paths.settingsFile).load()
    return settings.builder.signingIdentitySHA1?.uppercased() == sha1.uppercased()
  }

  func writeReport(_ report: BuildReport, to buildDir: URL) throws {
    try AtomicFile.write(try JSONCoding.encoder.encode(report), to: buildDir.appendingPathComponent("build-report.json"))
  }
}
