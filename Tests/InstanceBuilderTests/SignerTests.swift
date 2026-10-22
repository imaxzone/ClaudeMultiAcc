import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct SignerTests {
  let app = URL(fileURLWithPath: "/S/Claude Work.app")
  let ent = URL(fileURLWithPath: "/S/entitlements.plist")
  var spec: CloneSpec {
    CloneSpec.newClone(slug: testSlug("work"), displayName: "Claude Work", home: URL(fileURLWithPath: "/Users/t"))
  }

  /// `Claude.real` → outer bundle. Nothing under `Contents/Frameworks` is ever re-signed: the vendor helpers
  /// (library validation) refuse a Squirrel.framework with a different Team ID.
  @Test func adhocOrderNeverSignsFrameworks() async throws {
    let runner = ScriptedRunner()
    let commands = try await Signer(runner: runner).sign(app: app, spec: spec, entitlements: ent, identity: .adhoc)
    let base = ["codesign", "--force", "--timestamp=none", "--sign", "-"]
    #expect(runner.commandLines == [
      base + ["--options", "runtime", "-i", "com.imaxzone.claude.work", "--entitlements", "/S/entitlements.plist",
              "/S/Claude Work.app/Contents/MacOS/Claude.real"],
      base + ["--options", "runtime", "-i", "com.imaxzone.claude.work", "--entitlements", "/S/entitlements.plist",
              "/S/Claude Work.app"],
    ])
    #expect(runner.recorded.allSatisfy { $0.executable.path == "/usr/bin/codesign" && $0.timeout > .zero })
    #expect(commands.count == 2)
    #expect(!runner.commandLines.flatMap { $0 }.contains("--deep"))
    #expect(!runner.commandLines.flatMap { $0 }.contains { $0.contains("/Contents/Frameworks") })
  }

  @Test func certificateWithKeychain() async throws {
    let runner = ScriptedRunner()
    let keychain = URL(fileURLWithPath: "/tmp/secret dir/test.keychain-db")
    let commands = try await Signer(runner: runner).sign(
      app: app, spec: spec, entitlements: ent,
      identity: .certificate(sha1: "ABCDEF0123456789ABCDEF0123456789ABCDEF01", keychain: keychain))
    let base = ["codesign", "--force", "--timestamp=none", "--sign", "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
                "--keychain", "/tmp/secret dir/test.keychain-db"]
    #expect(runner.commandLines.count == 2)
    #expect(runner.commandLines[0] == base + ["--options", "runtime", "-i", "com.imaxzone.claude.work",
                                              "--entitlements", "/S/entitlements.plist",
                                              "/S/Claude Work.app/Contents/MacOS/Claude.real"])
    #expect(runner.commandLines[1].last == "/S/Claude Work.app")
    #expect(commands.allSatisfy { !$0.contains("secret dir") && $0.contains("<keychain>") })
  }

  @Test func certificateWithoutKeychainOmitsFlag() async throws {
    let runner = ScriptedRunner()
    _ = try await Signer(runner: runner).sign(
      app: app, spec: spec, entitlements: ent, identity: .certificate(sha1: "AB", keychain: nil))
    #expect(!runner.commandLines.flatMap { $0 }.contains("--keychain"))
  }

  /// A dedicated keychain (password stored beside it) is unlocked via `security -i` right before EVERY codesign run:
  /// codesign on a locked keychain would make macOS ask the user for a password they never saw.
  @Test func unlocksDedicatedKeychainBeforeEveryCodesign() async throws {
    let root = try makeTempDir()
    let keychain = SigningKeychain(url: root.appendingPathComponent("cmacc-signing.keychain-db"))
    try Data("0123abcd\n".utf8).write(to: keychain.passwordFile)
    let runner = ScriptedRunner()
    let ran = try await Signer(runner: runner).sign(
      app: app, spec: spec, entitlements: ent, identity: .certificate(sha1: testSHA1, keychain: keychain.url))
    #expect(runner.commandLines.map { $0[0] } == ["security", "codesign", "security", "codesign"])
    let unlocks = runner.recorded.filter { $0.executable.lastPathComponent == "security" }
    #expect(unlocks.allSatisfy { $0.arguments == ["-i"] })
    #expect(unlocks.allSatisfy {
      String(decoding: $0.stdin ?? Data(), as: UTF8.self) == "unlock-keychain -p \"0123abcd\" \"\(keychain.url.path)\"\n"
    })
    #expect(!runner.commandLines.flatMap { $0 }.contains { $0.contains("0123abcd") })
    #expect(runner.recorded.filter { $0.executable.lastPathComponent == "codesign" }.allSatisfy {
      $0.arguments.contains("--keychain") && $0.arguments.contains(keychain.url.path)
    })
    #expect(ran.count == 2 && ran.allSatisfy { $0.hasPrefix("codesign ") })
  }

  @Test func failedUnlockNeverRunsCodesign() async throws {
    let root = try makeTempDir()
    let keychain = SigningKeychain(url: root.appendingPathComponent("cmacc-signing.keychain-db"))
    try Data("0123abcd".utf8).write(to: keychain.passwordFile)
    let runner = ScriptedRunner { request in
      request.executable.lastPathComponent == "security"
        ? .fail(51, stderr: "unlock-keychain: returned -25293") : .ok()
    }
    await #expect(throws: SigningKeychainError.unlockFailed("unlock-keychain: returned -25293")) {
      _ = try await Signer(runner: runner).sign(
        app: app, spec: spec, entitlements: ent, identity: .certificate(sha1: testSHA1, keychain: keychain.url))
    }
    #expect(runner.commandLines.map { $0[0] } == ["security"])
  }

  @Test func emptyStoredPasswordIsRefusedBeforeCodesign() async throws {
    let root = try makeTempDir()
    let keychain = SigningKeychain(url: root.appendingPathComponent("k.keychain-db"))
    try Data("\n".utf8).write(to: keychain.passwordFile)
    let runner = ScriptedRunner()
    await #expect(throws: SigningKeychainError.passwordMissing(keychain.passwordFile.path)) {
      _ = try await Signer(runner: runner).sign(
        app: app, spec: spec, entitlements: ent, identity: .certificate(sha1: testSHA1, keychain: keychain.url))
    }
    #expect(runner.recorded.isEmpty)
  }

  /// The app's own keychain without its password file could only be opened by a macOS password prompt: refused.
  @Test func provisionedKeychainWithoutPasswordIsRefusedBeforeCodesign() async throws {
    let root = try makeTempDir()
    let keychain = SigningKeychain(url: root.appendingPathComponent(SigningIdentityProvisioner.keychainFileName))
    let runner = ScriptedRunner()
    await #expect(throws: SigningKeychainError.passwordMissing(keychain.passwordFile.path)) {
      _ = try await Signer(runner: runner).sign(
        app: app, spec: spec, entitlements: ent, identity: .certificate(sha1: testSHA1, keychain: keychain.url))
    }
    #expect(runner.recorded.isEmpty)
  }

  @Test func quotingRefusesWhatSecurityCannotParse() throws {
    #expect(try SigningKeychain.quoted("/Users/u/Library/Application Support/x") == "\"/Users/u/Library/Application Support/x\"")
    for bad in ["a\"b", "a\\b", "a\nb"] {
      #expect(throws: SigningKeychainError.unquotable) { try SigningKeychain.quoted(bad) }
    }
  }

  /// The refused value can be a keychain password: the error never carries it into logs or alerts.
  @Test func unquotableErrorCarriesNoValue() throws {
    let secret = "hunter\"2-secret"
    let error = try #require(#expect(throws: SigningKeychainError.self) { try SigningKeychain.quoted(secret) })
    #expect(error == .unquotable)
    for text in [String(describing: error), String(reflecting: error), error.userMessage, UserMessage.text(for: error)] {
      #expect(!text.contains("hunter"), "\(text)")
    }
  }

  @Test func stopsAtFirstFailure() async throws {
    let runner = ScriptedRunner { _ in .fail(1, stderr: "errSecInternalComponent") }
    await #expect(throws: BuilderError.commandFailed(tool: "codesign", exitCode: 1, stderr: "errSecInternalComponent")) {
      _ = try await Signer(runner: runner).sign(app: app, spec: spec, entitlements: ent, identity: .adhoc)
    }
    #expect(runner.recorded.count == 1)
  }

  @Test func parsesDesignatedRequirement() async throws {
    let runner = ScriptedRunner { _ in
      .ok(stdout: "designated => identifier \"com.imaxzone.claude.work\" and certificate leaf = H\"abc\"\n",
          stderr: "Executable=/S/Claude Work.app/Contents/MacOS/Claude\n")
    }
    let requirement = try await Signer(runner: runner).designatedRequirement(app: app)
    #expect(requirement == "identifier \"com.imaxzone.claude.work\" and certificate leaf = H\"abc\"")
    #expect(runner.commandLines == [["codesign", "-d", "-r-", "/S/Claude Work.app"]])
  }

  @Test func parsesImplicitAdhocRequirement() async throws {
    let runner = ScriptedRunner { _ in .ok(stdout: "# designated => cdhash H\"4e94\" or cdhash H\"abc5\"\n") }
    #expect(try await Signer(runner: runner).designatedRequirement(app: app) == "cdhash H\"4e94\" or cdhash H\"abc5\"")
  }

  @Test func missingDesignatedRequirementThrows() async {
    let runner = ScriptedRunner { _ in .ok(stderr: "Executable=/x\n") }
    await #expect(throws: BuilderError.noDesignatedRequirement) {
      _ = try await Signer(runner: runner).designatedRequirement(app: app)
    }
  }

  @Test func identityParsing() throws {
    #expect(try SigningIdentity.parse("adhoc", keychain: nil) == .adhoc)
    #expect(try SigningIdentity.parse("-", keychain: nil) == .adhoc)
    let sha = "abcdef0123456789abcdef0123456789abcdef01"
    #expect(try SigningIdentity.parse(sha, keychain: nil) == .certificate(sha1: sha.uppercased(), keychain: nil))
    #expect(throws: SigningIdentityError.self) { try SigningIdentity.parse("Developer ID", keychain: nil) }
    #expect(throws: SigningIdentityError.self) {
      try SigningIdentity.parse("adhoc", keychain: URL(fileURLWithPath: "/k"))
    }
    #expect(SigningIdentity.adhoc.kind == "adhoc")
    #expect(SigningIdentity.certificate(sha1: "AB", keychain: nil).kind == "certificate")
  }
}
