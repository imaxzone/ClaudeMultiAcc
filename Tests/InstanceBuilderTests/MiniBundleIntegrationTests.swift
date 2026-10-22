import CoreGraphics
import Foundation
import IconRenderer
import Support
import Testing
@testable import InstanceBuilder

/// Runs the whole pipeline on a hermetic mini `Claude.app` with the real `cp`, `xattr`, `iconutil` and
/// ad hoc `codesign`. Nothing outside the temp dir is touched and nothing is launched.
@Suite(.serialized) struct MiniBundleIntegrationTests {
  let runner = SystemProcessRunner()

  private func signSource(_ app: URL) async throws {
    let targets = [
      "Contents/Frameworks/Claude Helper.app",
      "Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt",
      "Contents/Frameworks/Squirrel.framework/Versions/A",
      "",
    ]
    for target in targets {
      let path = target.isEmpty ? app.path : app.appendingPathComponent(target).path
      let result = try await runner.run(ProcessRequest(
        executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", path], timeout: .seconds(60)))
      #expect(result.exitCode == 0, "codesign \(target): \(result.stderrText)")
    }
  }

  private func makeSource(in root: URL) async throws -> URL {
    let binary = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
    let icnsWork = root.appendingPathComponent("icns-work")
    let icns = root.appendingPathComponent("electron.icns")
    let base = try #require(solidImage(side: 1024))
    try await IcnsTool(runner: runner).writeIcns(from: base, to: icns, workDir: icnsWork)
    let app = try MiniBundle.makeSource(in: root.appendingPathComponent("src"), executable: binary,
                                        icns: try Data(contentsOf: icns))
    try await signSource(app)
    return app
  }

  @Test func adhocBuildOfMiniBundleVerifies() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await makeSource(in: root)
    let launcher = root.appendingPathComponent("CloneLauncher")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: launcher)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let spec = CloneSpec.newClone(slug: testSlug("itest"), displayName: "Claude Itest", home: root)
      .with(badge: "T")
    let environment = BuildEnvironment(
      running: FakeRunningCheck(running: false), vendorUpdate: { _ in FakeVendorUpdateCheck(state: .idle) },
      availableBytes: BuildEnvironment.volumeAvailableBytes, sourcePolicy: .relaxedForTests)
    let icons = FakeIconProvider(side: nil)
    let pipeline = InstanceBuildPipeline(
      paths: paths, runner: runner, launcherBinary: launcher, clock: SystemClock(), environment: environment,
      iconProvider: icons, officialAppsRoot: root.appendingPathComponent("no-such-apps"))

    let report = try await pipeline.build(spec: spec, source: source, identity: .adhoc, intent: .stagingOnly)

    #expect(report.verified, "failure: \(String(describing: report.failure)); steps: \(report.steps.filter { !$0.ok })")
    #expect(report.verification.allSatisfy { $0.passed })
    #expect(report.smoke.allSatisfy { $0.passed }, "\(report.smoke.filter { !$0.passed })")
    let staged = URL(fileURLWithPath: report.stagedPath)
    // R1: the badge went into electron.icns with the real iconutil before signing (verify ran `--strict`).
    #expect(report.steps.first { $0.name == "badge" }?.detail == "base=electron.icns 1024px")
    #expect(icons.requested.isEmpty)
    let icns = "Contents/Resources/electron.icns"
    let badged = try await IcnsTool(runner: runner).extractLargest(
      from: staged.appendingPathComponent(icns), workDir: root.appendingPathComponent("check-icns"))
    #expect(badged.width == 1024)
    #expect(StaticSmoke.sha256(of: staged.appendingPathComponent(icns)) != StaticSmoke.sha256(of: source.appendingPathComponent(icns)))
    let info = try plistDict(Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")))
    #expect(info["CFBundleIconName"] == nil && info["NSDockTilePlugIn"] == nil)
    #expect(staged.path.hasPrefix(paths.stagingDir.path))
    #expect(staged.deletingLastPathComponent().lastPathComponent.hasSuffix(".noindex"))
    let details = try await runner.run(ProcessRequest(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"),
      arguments: ["-dv", "--verbose=2", staged.appendingPathComponent("Contents/MacOS/Claude.real").path], timeout: .seconds(30)))
    #expect(details.stderrText.contains("Identifier=com.imaxzone.claude.itest"))
    #expect(details.stderrText.contains("runtime"))
    try expectSquirrelUntouched(staged: staged, source: source)
    #expect(report.smoke.first { $0.name == "vendor-frameworks-intact" }?.passed == true)
    #expect(try StagingArea(paths: paths).discard(slug: spec.slug) == 1)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(VendorFrameworksCheck.shipItPath).path))
  }

  /// The staged Squirrel.framework is the vendor's, byte for byte: same entries, same `Squirrel` and `ShipIt`, and
  /// the same code signature (a re-signed Squirrel makes every vendor helper crash under library validation).
  private func expectSquirrelUntouched(staged: URL, source: URL) throws {
    let squirrel = "Contents/Frameworks/Squirrel.framework"
    let stagedTree = try MiniBundle.treeDigest(staged.appendingPathComponent(squirrel))
    #expect(stagedTree == (try MiniBundle.treeDigest(source.appendingPathComponent(squirrel))))
    for file in ["Versions/A/Squirrel", "Versions/A/Resources/ShipIt", "Versions/A/_CodeSignature/CodeResources"] {
      let stagedHash = StaticSmoke.sha256(of: staged.appendingPathComponent("\(squirrel)/\(file)"))
      #expect(stagedHash != nil && stagedHash == StaticSmoke.sha256(of: source.appendingPathComponent("\(squirrel)/\(file)")),
              "\(file)")
    }
  }
}
