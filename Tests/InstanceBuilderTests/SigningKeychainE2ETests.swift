import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Opt-in end-to-end run against the real `security`, `openssl` and `codesign` (R2 item 2, like experiment E2). It
/// never runs in a plain `swift test` or CI: it needs BOTH variables, and the dir must lie under `/private/tmp`:
///
///     CMACC_E2E_KEYCHAIN=1 CMACC_E2E_KEYCHAIN_DIR=/private/tmp/…/scratch swift test --filter SigningKeychainE2ETests
///
/// Provisions a dedicated keychain in a temp data dir under that dir, signs a dummy bundle through `Signer` (with the
/// keychain locked first, as after a restart), verifies it, checks that a second `ensureIdentity()` reuses the
/// identity, and ALWAYS deletes the keychain again. Every command goes through `GuardedKeychainRunner`; the user
/// search list must be unchanged throughout. Notes go to `<dir>/e2e-transcript.txt`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMACC_E2E_KEYCHAIN"] == "1"))
struct SigningKeychainE2ETests {
  @Test func provisionSignVerifyDelete() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["CMACC_E2E_KEYCHAIN_DIR"], "CMACC_E2E_KEYCHAIN_DIR not set")
    // realpath(3), not resolvingSymlinksInPath (which strips `/private`): the keychain must never leave /private/tmp.
    let resolved = try #require(realpath(raw, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    }, "CMACC_E2E_KEYCHAIN_DIR must exist")
    try #require(raw.hasPrefix("/") && resolved.hasPrefix("/private/tmp/"), "the e2e dir must be under /private/tmp")
    let base = URL(fileURLWithPath: resolved, isDirectory: true)
    let root = base.appendingPathComponent("e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let paths = Paths(home: root.appendingPathComponent("home"), dataDir: root.appendingPathComponent("data"),
                      logsDir: root.appendingPathComponent("logs"))
    let keychain = SigningIdentityProvisioner.defaultKeychain(paths: paths)
    let log = E2ETranscript(file: base.appendingPathComponent("e2e-transcript.txt"), root: root)
    let runner = GuardedKeychainRunner(root: root, keychain: keychain, transcript: log)
    let before = try await searchList(runner)
    log.add("search list before: \(before)")
    var failure: (any Error)?
    do {
      try await provisionAndSign(paths: paths, root: root, runner: runner, before: before, log: log)
    } catch {
      failure = error
      log.add("FAILED: \(error)")
    }
    try await deleteKeychain(SigningKeychain(url: keychain), runner: runner, log: log)
    let after = try await searchList(runner)
    log.add("search list after delete: \(after) (unchanged: \(after == before))")
    #expect(after == before)
    #expect(!FileManager.default.fileExists(atPath: keychain.path))
    let stray = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Keychains/\(SigningIdentityProvisioner.keychainFileName)")
    #expect(!FileManager.default.fileExists(atPath: stray.path), "nothing may land in ~/Library/Keychains")
    try? FileManager.default.removeItem(at: root)
    if let failure { throw failure }
  }

  private func provisionAndSign(
    paths: Paths, root: URL, runner: GuardedKeychainRunner, before: String, log: E2ETranscript
  ) async throws {
    let provisioner = SigningIdentityProvisioner(paths: paths, runner: runner)
    let identity = try await provisioner.ensureIdentity()
    guard case .certificate(let sha1, let keychainURL?) = identity else { Issue.record("not a keychain identity"); return }
    let keychain = SigningKeychain(url: keychainURL)
    log.add("ensureIdentity #1 → \(sha1) in \(keychainURL.lastPathComponent)")
    #expect(keychainURL == SigningIdentityProvisioner.defaultKeychain(paths: paths))
    let during = try await searchList(runner)
    log.add("search list after provisioning unchanged: \(during == before)")
    #expect(during == before)
    try await expectRecords(paths: paths, sha1: sha1, keychain: keychain, runner: runner, log: log)

    let created = runner.labels.filter { $0 == "security -i create-keychain" }.count
    let second = try await provisioner.ensureIdentity()
    log.add("ensureIdentity #2 → same identity: \(second == identity); create-keychain runs: \(created) → "
      + "\(runner.labels.filter { $0 == "security -i create-keychain" }.count)")
    #expect(second == identity)
    #expect(runner.labels.filter { $0 == "security -i create-keychain" }.count == 1)

    await expectWrongPasswordFails(keychain, runner: runner, log: log)
    // Lock it on purpose, as after a restart: Signer must unlock right before each codesign run.
    let locked = try await runner.run(request(["lock-keychain", keychainURL.path]))
    log.add("lock-keychain → exit \(locked.exitCode)")
    let app = try makeBundle(in: root)
    let spec = CloneSpec.newClone(slug: testSlug("e2e"), displayName: "Claude E2E", home: paths.home)
    let entitlements = root.appendingPathComponent("entitlements.plist")
    try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0).write(to: entitlements)
    let lines = try await Signer(runner: runner).sign(
      app: app, spec: spec, entitlements: entitlements, identity: identity)
    for line in lines { log.add("signed: \(line)") }
    try await expectValidSignature(app, sha1: sha1, runner: runner, log: log)
  }

  private func expectRecords(
    paths: Paths, sha1: String, keychain: SigningKeychain, runner: GuardedKeychainRunner, log: E2ETranscript
  ) async throws {
    let files = try FileManager.default.contentsOfDirectory(atPath: paths.signingDir.path).sorted()
    log.add("signing dir: \(files.joined(separator: ", "))")
    // securityd keeps its own `.fl<hash>` lock file beside every keychain file (like those in ~/Library/Keychains).
    #expect(files.filter { !$0.hasPrefix(".fl") }
      == [".provision.lock", "cmacc-signing.keychain-db", "identity.json", "keychain-password"])
    let modes = try (posixMode(keychain.passwordFile), posixMode(paths.identityFile), posixMode(paths.signingDir))
    log.add("modes: keychain-password \(String(modes.0, radix: 8)), identity.json \(String(modes.1, radix: 8)), "
      + "signing/ \(String(modes.2, radix: 8))")
    #expect(modes.0 == 0o600 && modes.1 == 0o600 && modes.2 == 0o700)
    let builder = await SettingsStore(file: paths.settingsFile).load().builder
    #expect(builder.signingIdentitySHA1 == sha1 && builder.signingKeychainPath == keychain.url.path)
    try await keychain.unlock(runner: runner)
    let info = try await runner.run(request(["show-keychain-info", keychain.url.path]))
    log.add("show-keychain-info: \((info.stdoutText + info.stderrText).trimmingCharacters(in: .whitespacesAndNewlines))")
    #expect((info.stdoutText + info.stderrText).contains("no-timeout"), "the keychain must never auto-lock")
    let listed = await SigningIdentityCheck.identityHashes(in: keychain, runner: runner)
    log.add("find-identity (after unlock) → \(listed.sorted())")
    #expect(listed == [sha1])
  }

  /// `security -i` must report a failed command through its exit status, without the password in the error.
  private func expectWrongPasswordFails(_ keychain: SigningKeychain, runner: GuardedKeychainRunner, log: E2ETranscript) async {
    let wrong = "not-the-password-\(UUID().uuidString.prefix(6))"
    do {
      try await SigningKeychain.interactive(
        runner, "unlock-keychain -p \"\(wrong)\" \"\(keychain.url.path)\"", secrets: [wrong]) { .unlockFailed($0) }
      Issue.record("a wrong password unlocked the keychain")
    } catch SigningKeychainError.unlockFailed(let stderr) {
      log.add("wrong password → unlockFailed, stderr redacted: \(!stderr.contains(wrong))")
      #expect(!stderr.contains(wrong))
    } catch {
      Issue.record("unexpected \(error)")
    }
  }

  private func expectValidSignature(_ app: URL, sha1: String, runner: GuardedKeychainRunner, log: E2ETranscript) async throws {
    let verify = try await runner.run(request(["--verify", "--strict", "--verbose=2", app.path], tool: "/usr/bin/codesign"))
    log.add("codesign --verify --strict → exit \(verify.exitCode): "
      + verify.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))
    #expect(verify.exitCode == 0)
    let details = try await runner.run(request(["-dv", "--verbose=2", app.path], tool: "/usr/bin/codesign")).stderrText
    let authority = details.split(separator: "\n").filter { $0.hasPrefix("Authority") || $0.hasPrefix("TeamIdentifier") }
    log.add(authority.joined(separator: "; "))
    #expect(authority.contains { $0 == "Authority=\(SigningIdentityCheck.commonName)" })
    let requirement = try await Signer(runner: runner).designatedRequirement(app: app)
    log.add("designated => \(requirement)")
    #expect(requirement.contains("certificate leaf = H\"\(sha1.lowercased())\""))
  }

  /// Unlocks (if its password is still there) and deletes the test keychain; a missing keychain is fine.
  private func deleteKeychain(_ keychain: SigningKeychain, runner: GuardedKeychainRunner, log: E2ETranscript) async throws {
    guard FileManager.default.fileExists(atPath: keychain.url.path) else { log.add("no keychain to delete"); return }
    if keychain.hasStoredPassword { try? await keychain.unlock(runner: runner) }
    let deleted = try await runner.run(request(["delete-keychain", keychain.url.path]))
    log.add("delete-keychain → exit \(deleted.exitCode)")
    #expect(deleted.exitCode == 0)
  }

  private func makeBundle(in root: URL) throws -> URL {
    let app = root.appendingPathComponent("Claude E2E.app", isDirectory: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.imaxzone.claude.e2e", "CFBundleExecutable": "Claude", "CFBundleName": "Claude E2E",
      "CFBundlePackageType": "APPL",
    ]
    try MiniBundle.write(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
                         app.appendingPathComponent("Contents/Info.plist"))
    let binary = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
    try MiniBundle.write(binary, app.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
    try MiniBundle.write(binary, app.appendingPathComponent("Contents/MacOS/Claude.real"), mode: 0o755)
    return app
  }

  private func searchList(_ runner: GuardedKeychainRunner) async throws -> String {
    try await runner.run(request(["list-keychains", "-d", "user"])).stdoutText
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func request(_ arguments: [String], tool: String = "/usr/bin/security") -> ProcessRequest {
    ProcessRequest(executable: URL(fileURLWithPath: tool), arguments: arguments, timeout: GuardedKeychainRunner.cap)
  }
}
