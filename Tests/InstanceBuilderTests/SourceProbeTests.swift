import CryptoKit
import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct SourceProbeTests {
  static func codesignFake(team: String = "Q6L2SF6YDW", verifyExit: Int32 = 0) -> ScriptedRunner {
    ScriptedRunner { request in
      if request.arguments.first == "--verify" { return verifyExit == 0 ? .ok() : .fail(verifyExit, stderr: "invalid signature") }
      return .ok(stderr: "Identifier=com.anthropic.claudefordesktop\nTeamIdentifier=\(team)\n")
    }
  }

  @Test func probeReadsVersionTeamAndHash() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root, executable: Data("electron-main".utf8))
    let runner = Self.codesignFake()
    let info = try await SourceProbe(runner: runner).probe(app)
    #expect(info.bundleId == "com.anthropic.claudefordesktop")
    #expect(info.version == "2.7032.0")
    #expect(info.teamId == "Q6L2SF6YDW")
    #expect(info.mainExecutableSHA256 == SHA256.hash(data: Data("electron-main".utf8)).map { String(format: "%02x", $0) }.joined())
    #expect(runner.commandLines == [
      ["codesign", "-dv", "--verbose=2", app.path], ["codesign", "--verify", "--strict", app.path],
    ])
  }

  @Test func wrongTeamIsRefusedUnlessRelaxed() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root)
    await #expect(throws: BuilderError.unexpectedTeamId(expected: "Q6L2SF6YDW", found: "not set")) {
      _ = try await SourceProbe(runner: Self.codesignFake(team: "not set")).probe(app)
    }
    let relaxed = try await SourceProbe(runner: Self.codesignFake(team: "not set"), policy: .relaxedForTests).probe(app)
    #expect(relaxed.teamId == "not set")
  }

  @Test func invalidSignatureIsRefused() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root)
    await #expect(throws: BuilderError.sourceSignatureInvalid("invalid signature")) {
      _ = try await SourceProbe(runner: Self.codesignFake(verifyExit: 1)).probe(app)
    }
  }

  @Test func wrongBundleIdAndMissingAppAreRefused() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root)
    let spec = CloneSpec.newClone(slug: testSlug("x"), displayName: "X", home: root)
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    try PlistPatcher.patch(try Data(contentsOf: infoURL), spec: spec).write(to: infoURL)
    await #expect(throws: BuilderError.unexpectedSourceBundleId("com.imaxzone.claude.x")) {
      _ = try await SourceProbe(runner: Self.codesignFake()).probe(app)
    }
    let missing = root.appendingPathComponent("Nope.app")
    await #expect(throws: BuilderError.sourceUnreadable(missing.path)) {
      _ = try await SourceProbe(runner: Self.codesignFake()).probe(missing)
    }
  }
}
