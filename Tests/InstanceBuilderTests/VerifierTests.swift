import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct VerifierTests {
  let app = URL(fileURLWithPath: "/S/Claude Work.app")
  var spec: CloneSpec {
    CloneSpec.newClone(slug: testSlug("work"), displayName: "Claude Work", home: URL(fileURLWithPath: "/Users/t"))
  }

  static func entitlementsXML() throws -> String {
    String(decoding: try EntitlementsFilter.filter(try fixtureData("entitlements-claude.plist")), as: UTF8.self)
  }

  /// Answers like codesign for a correctly signed clone; `overrides` replaces answers by a key of the request.
  static func codesignFake(
    identifier: String = "com.imaxzone.claude.work", flags: String = "0x10002(adhoc,runtime)",
    verifyExit: Int32 = 0, helperTeam: String = "Q6L2SF6YDW", entitlements: String
  ) -> ScriptedRunner {
    ScriptedRunner { request in
      let args = request.arguments
      if args.first == "--verify" {
        return verifyExit == 0 ? .ok(stderr: "\(args.last ?? ""): valid on disk\n") : .fail(verifyExit, stderr: "a sealed resource is missing or invalid")
      }
      if args.contains("--entitlements") { return .ok(stdout: entitlements) }
      if let target = args.last, target.hasSuffix("Claude Helper.app") {
        return .ok(stderr: "Identifier=com.anthropic.claudefordesktop.helper\nTeamIdentifier=\(helperTeam)\n")
      }
      return .ok(stderr: "Executable=x\nIdentifier=\(identifier)\nCodeDirectory v=20500 size=1 flags=\(flags) hashes=1+1\n")
    }
  }

  @Test func passesForCorrectClone() async throws {
    let xml = try Self.entitlementsXML()
    let runner = Self.codesignFake(entitlements: xml)
    let result = try await Verifier(runner: runner).verify(app: app, spec: spec, expectedEntitlements: Data(xml.utf8))
    #expect(result.passed, "\(result.checks.filter { !$0.passed })")
    #expect(result.checks.map(\.name) == [
      "codesign-verify-deep-strict", "app-identifier", "app-runtime", "real-identifier", "real-runtime",
      "real-entitlements", "helper-team-id",
    ])
    #expect(runner.commandLines.first == ["codesign", "--verify", "--deep", "--strict", "--verbose=2", app.path])
    #expect(runner.commandLines.contains(["codesign", "-dv", "--verbose=4", app.path + "/Contents/MacOS/Claude.real"]))
    #expect(runner.commandLines.contains(["codesign", "-d", "--entitlements", "-", "--xml",
                                          app.path + "/Contents/MacOS/Claude.real"]))
  }

  @Test func failsOnWrongIdentifierMissingRuntimeAndBadVerify() async throws {
    let xml = try Self.entitlementsXML()
    let runner = Self.codesignFake(identifier: "com.anthropic.claudefordesktop", flags: "0x2(adhoc)", verifyExit: 1,
                                   entitlements: xml)
    let result = try await Verifier(runner: runner).verify(app: app, spec: spec, expectedEntitlements: Data(xml.utf8))
    #expect(!result.passed)
    let failed = Set(result.checks.filter { !$0.passed }.map(\.name))
    #expect(failed == ["codesign-verify-deep-strict", "app-identifier", "app-runtime", "real-identifier", "real-runtime"])
  }

  @Test func failsOnEntitlementMismatchAndForeignHelperTeam() async throws {
    let runner = Self.codesignFake(helperTeam: "not set", entitlements: try Self.entitlementsXML())
    let other = try PropertyListSerialization.data(fromPropertyList: ["x": true], format: .xml, options: 0)
    let result = try await Verifier(runner: runner).verify(app: app, spec: spec, expectedEntitlements: other)
    let failed = Set(result.checks.filter { !$0.passed }.map(\.name))
    #expect(failed == ["real-entitlements", "helper-team-id"])
  }

  @Test func withoutExpectedEntitlementsChecksInvariants() async throws {
    let good = Self.codesignFake(entitlements: try Self.entitlementsXML())
    #expect(try await Verifier(runner: good).verify(app: app, spec: spec, expectedEntitlements: nil).passed)
    let vendor = String(decoding: try fixtureData("entitlements-claude.plist"), as: UTF8.self)
    let bad = Self.codesignFake(entitlements: vendor)
    let result = try await Verifier(runner: bad).verify(app: app, spec: spec, expectedEntitlements: nil)
    #expect(result.checks.first { $0.name == "real-entitlements" }?.passed == false)
  }

  @Test func helperTeamCheckCanBeSkipped() async throws {
    let runner = Self.codesignFake(helperTeam: "not set", entitlements: try Self.entitlementsXML())
    let result = try await Verifier(runner: runner, helperTeamId: nil).verify(app: app, spec: spec, expectedEntitlements: nil)
    #expect(result.passed)
    #expect(result.checks.first { $0.name == "helper-team-id" }?.detail.hasPrefix("skipped") == true)
  }

  /// A clone folder whose bundle root holds `Contents` plus the given empty files.
  private func installedApp(rootFiles: [String], _ name: String = #function) throws -> URL {
    let app = try makeTempDir(name).appendingPathComponent("Claude Work.app", isDirectory: true)
    try MiniBundle.write(Data("<plist/>".utf8), app.appendingPathComponent("Contents/Info.plist"))
    for file in rootFiles { try Data().write(to: app.appendingPathComponent(file)) }
    return app
  }

  /// An installed clone carries its badge as a Finder custom icon: `Icon\r` is reported as an informational pass,
  /// codesign runs without `--strict` and a separate check requires nothing else unsealed in the bundle root.
  @Test func customIconOfAnInstalledCloneIsToleratedWithoutStrict() async throws {
    let xml = try Self.entitlementsXML()
    let app = try installedApp(rootFiles: ["Icon\r"])
    let runner = Self.codesignFake(entitlements: xml)
    let result = try await Verifier(runner: runner)
      .verify(app: app, spec: spec, expectedEntitlements: Data(xml.utf8), allowCustomIcon: true)
    #expect(result.passed, "\(result.checks.filter { !$0.passed })")
    #expect(result.checks.map(\.name) == [
      "custom-icon", "codesign-verify-deep", "bundle-root-sealed", "app-identifier", "app-runtime", "real-identifier",
      "real-runtime", "real-entitlements", "helper-team-id",
    ])
    #expect(result.checks.first?.detail.hasPrefix("present") == true)
    #expect(runner.commandLines.first == ["codesign", "--verify", "--deep", "--verbose=2", app.path])
    #expect(!runner.commandLines.contains { $0.contains("--strict") })
  }

  @Test func anotherUnsealedFileInTheBundleRootFails() async throws {
    let xml = try Self.entitlementsXML()
    let app = try installedApp(rootFiles: ["Icon\r", "notes.txt"])
    let result = try await Verifier(runner: Self.codesignFake(entitlements: xml))
      .verify(app: app, spec: spec, expectedEntitlements: Data(xml.utf8), allowCustomIcon: true)
    #expect(!result.passed)
    #expect(result.checks.filter { !$0.passed } == [SmokeCheck("bundle-root-sealed", false, "unsealed: notes.txt")])
  }

  /// No icon file, or a staged build (the pipeline never allows it): the strict verification as before.
  @Test func withoutACustomIconOrPermissionVerificationStaysStrict() async throws {
    let xml = try Self.entitlementsXML()
    for (files, allow) in [([String](), true), (["Icon\r"], false)] {
      let app = try installedApp(rootFiles: files, "strict-\(allow)")
      let runner = Self.codesignFake(entitlements: xml)
      let result = try await Verifier(runner: runner)
        .verify(app: app, spec: spec, expectedEntitlements: Data(xml.utf8), allowCustomIcon: allow)
      #expect(result.checks.first?.name == "codesign-verify-deep-strict")
      #expect(!result.checks.contains { $0.name == "custom-icon" })
      #expect(runner.commandLines.first == ["codesign", "--verify", "--deep", "--strict", "--verbose=2", app.path])
    }
  }

  @Test func flagParsing() {
    #expect(Verifier.flags(in: "CodeDirectory v=20500 size=458 flags=0x10000(runtime) hashes=3+7") == ["runtime"])
    #expect(Verifier.flags(in: "flags=0x10002(adhoc,runtime)") == ["adhoc", "runtime"])
    #expect(Verifier.flags(in: "flags=0x0(none)") == ["none"])
    #expect(Verifier.flags(in: "nothing").isEmpty)
    #expect(Verifier.value(of: "TeamIdentifier", in: "A=1\nTeamIdentifier=Q6L2SF6YDW\n") == "Q6L2SF6YDW")
  }
}
