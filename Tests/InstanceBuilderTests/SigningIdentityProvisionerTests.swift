import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// A fake `/usr/bin/security` + `/usr/bin/openssl`: one dedicated keychain file, its password and identities, plus
/// the user search list and the login keychain (`find-certificate`). Keychain files are real (empty) files on disk.
final class KeychainWorld: Sendable {
  struct State {
    var password: String?
    var identities: [String] = []
    var loginIdentities: [String] = []
    var searchList = "    \"/Users/u/Library/Keychains/login.keychain-db\"\n"
    var searchListAfterCreate: String?
    var failImport: String?
    var legacyOpenSSL = false
    var unlockTimesOut = false
    var p12Password: String?
  }

  static let newSHA1 = String(repeating: "C3", count: 20)
  let state: Mutex<State>

  init(_ state: State = State()) {
    self.state = Mutex(state)
  }

  var runner: ScriptedRunner { ScriptedRunner { [self] request in try answer(request) } }

  private func answer(_ request: ProcessRequest) throws -> ProcessResult {
    let args = request.arguments
    switch request.executable.path {
    case "/usr/bin/openssl": return openssl(args, request)
    case "/usr/bin/security": break
    default: return .ok()
    }
    if args == ["-i"] { return interactive(String(decoding: request.stdin ?? Data(), as: UTF8.self)) }
    switch args.first {
    case "list-keychains": return .ok(stdout: state.withLock { $0.searchList })
    case "find-identity":
      let lines = state.withLock { $0.identities }.enumerated()
        .map { "  \($0.offset + 1)) \($0.element) \"\(SigningIdentityCheck.commonName)\" (CSSMERR_TP_NOT_TRUSTED)" }
      return .ok(stdout: "\nPolicy: Code Signing\n  Matching identities\n" + lines.joined(separator: "\n")
        + "\n     \(lines.count) identities found\n\n  Valid identities only\n     0 valid identities found\n")
    case "find-certificate":
      let hashes = state.withLock { $0.loginIdentities }
      guard !hashes.isEmpty else { return .fail(44, stderr: "The specified item could not be found in the keychain.") }
      return .ok(stdout: hashes.map { "SHA-1 hash: \($0)\n" }.joined())
    case "delete-keychain":
      try? FileManager.default.removeItem(atPath: args[1])
      state.withLock { $0.identities = []; $0.password = nil; $0.searchListAfterCreate = nil }
      return .ok()
    default: return .ok()
    }
  }

  private func openssl(_ args: [String], _ request: ProcessRequest) -> ProcessResult {
    if args.contains("-help") {
      return .fail(1, stderr: state.withLock { $0.legacyOpenSSL } ? "usage: pkcs12 -legacy ..." : "usage: pkcs12 ...")
    }
    switch args.first {
    case "pkcs12":
      let line = String(decoding: request.stdin ?? Data(), as: UTF8.self)
      state.withLock { $0.p12Password = line.hasSuffix("\n") ? String(line.dropLast()) : nil }
      return .ok()
    case "x509":
      let pairs = stride(from: 0, to: 40, by: 2).map { i -> String in
        let start = Self.newSHA1.index(Self.newSHA1.startIndex, offsetBy: i)
        return String(Self.newSHA1[start..<Self.newSHA1.index(start, offsetBy: 2)])
      }
      return .ok(stdout: "SHA1 Fingerprint=\(pairs.joined(separator: ":"))\n")
    default: return .ok(stderr: "Generating a 2048 bit RSA private key\n")
    }
  }

  private func interactive(_ line: String) -> ProcessResult {
    let words = line.split(separator: " ").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\n")) }
    switch words.first {
    case "create-keychain":
      FileManager.default.createFile(atPath: words[3], contents: Data())
      state.withLock { $0.password = words[2]; if let after = $0.searchListAfterCreate { $0.searchList = after } }
      return .ok()
    case "unlock-keychain":
      if state.withLock({ $0.unlockTimesOut }) {
        return ProcessResult(exitCode: 143, stdout: Data(), stderr: Data(), timedOut: true)
      }
      return state.withLock { $0.password } == words[2] ? .ok() : .fail(51, stderr: "unlock-keychain: returned -25293")
    case "import":
      if let failure = state.withLock({ $0.failImport }) { return .fail(1, stderr: failure) }
      let password = words.last
      guard password == state.withLock({ $0.p12Password }) else { return .fail(1, stderr: "MAC verification failed") }
      state.withLock { $0.identities.append(Self.newSHA1) }
      return .ok()
    default: return .ok()
    }
  }
}

@Suite struct SigningIdentityProvisionerTests {
  struct Fixture {
    let paths: Paths
    let world: KeychainWorld
    let runner: ScriptedRunner
    var keychain: URL { paths.signingDir.appendingPathComponent("cmacc-signing.keychain-db") }
    var passwordFile: URL { paths.signingDir.appendingPathComponent("keychain-password") }
    var provisioner: SigningIdentityProvisioner {
      SigningIdentityProvisioner(paths: paths, runner: runner, clock: FixedClock(now: Date(timeIntervalSince1970: 1_790_000_000)))
    }
    var settings: AppSettings.Builder { get async { await SettingsStore(file: paths.settingsFile).load().builder } }
    var interactiveLines: [String] {
      runner.recorded.filter { $0.arguments == ["-i"] }.map { String(decoding: $0.stdin ?? Data(), as: UTF8.self) }
    }
    func lines(starting verb: String) -> [String] { interactiveLines.filter { $0.hasPrefix(verb + " ") } }
  }

  func fixture(_ state: KeychainWorld.State = .init()) throws -> Fixture {
    let root = try makeTempDir()
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let world = KeychainWorld(state)
    return Fixture(paths: paths, world: world, runner: world.runner)
  }

  @Test func createsDedicatedIdentityWhenNothingIsRecorded() async throws {
    let f = try fixture()
    let identity = try await f.provisioner.ensureIdentity()
    #expect(identity == .certificate(sha1: KeychainWorld.newSHA1, keychain: f.keychain))
    let builder = await f.settings
    #expect(builder.signingIdentitySHA1 == KeychainWorld.newSHA1)
    #expect(builder.signingKeychainPath == f.keychain.path)
    let password = try String(contentsOf: f.passwordFile, encoding: .utf8)
    #expect(password.count == 64 && password.allSatisfy(\.isHexDigit))
    #expect(try posixMode(f.passwordFile) == 0o600)
    #expect(try posixMode(f.paths.identityFile) == 0o600)
    #expect(try posixMode(f.paths.signingDir) == 0o700)
    let record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.paths.identityFile)) as? [String: String])
    #expect(record["sha1"] == KeychainWorld.newSHA1 && record["keychain"] == f.keychain.path)
    #expect(record["commonName"] == "ClaudeMultiAcc Local Signing" && record["createdAt"] == "2026-09-21T14:13:20Z")
    // Every keychain command with a secret went through stdin, one command per `security -i` run, in this order.
    let verbs = f.interactiveLines.map { String($0.prefix { $0 != " " }) }
    #expect(Array(verbs.prefix(4)) == ["create-keychain", "unlock-keychain", "import", "set-key-partition-list"])
    #expect(f.interactiveLines.allSatisfy { $0.filter { $0 == "\n" }.count == 1 })
    let p12 = try #require(f.world.state.withLock { $0.p12Password })
    #expect(f.lines(starting: "import") == [
      "import \"\(f.paths.signingDir.path)/\(try #require(workDirName(f)))/identity.p12\" -k \"\(f.keychain.path)\" "
        + "-f pkcs12 -x -T /usr/bin/codesign -P \"\(p12)\"\n",
    ])
    #expect(f.lines(starting: "set-key-partition-list") == [
      "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \"\(password)\" \"\(f.keychain.path)\"\n",
    ])
    let argv = f.runner.recorded.flatMap(\.arguments)
    #expect(!argv.contains { $0.contains(password) || $0.contains(p12) })
    expectNoForbiddenKeychainCommands(f.runner)
    #expect(f.runner.commandLines.contains(["security", "set-keychain-settings", f.keychain.path]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.signingDir.path).allSatisfy { !$0.hasPrefix(".provision-") })
  }

  @Test func certificateMatchesSigningSetup() async throws {
    let f = try fixture()
    _ = try await f.provisioner.ensureIdentity()
    let openssl = f.runner.recorded.filter { $0.executable.path == "/usr/bin/openssl" }
    let req = try #require(openssl.first { $0.arguments.first == "req" }).arguments
    for flag in ["-x509", "-nodes", "/CN=ClaudeMultiAcc Local Signing", "keyUsage=critical,digitalSignature",
                 "extendedKeyUsage=codeSigning", "3650", "rsa:2048"] {
      #expect(req.contains(flag), "req lacks \(flag)")
    }
    let export = try #require(openssl.first { $0.arguments.prefix(2) == ["pkcs12", "-export"] })
    #expect(export.arguments.suffix(2) == ["-passout", "stdin"])
    #expect(!export.arguments.contains("-legacy"))
    let p12 = try #require(f.world.state.withLock { $0.p12Password })
    #expect(p12.count == 32 && p12.allSatisfy(\.isHexDigit))
    #expect(export.stdin == Data((p12 + "\n").utf8))
  }

  @Test func legacyFlagOnlyForOpenSSL3() async throws {
    var state = KeychainWorld.State()
    state.legacyOpenSSL = true
    let f = try fixture(state)
    _ = try await f.provisioner.ensureIdentity()
    let export = try #require(f.runner.recorded.first { $0.arguments.prefix(2) == ["pkcs12", "-export"] })
    #expect(export.arguments.contains("-legacy"))
  }

  @Test func secondCallReusesTheIdentityAndOnlyUnlocks() async throws {
    let f = try fixture()
    let first = try await f.provisioner.ensureIdentity()
    let before = f.runner.recorded.count
    let second = try await f.provisioner.ensureIdentity()
    #expect(first == second)
    let later = f.runner.commandLines.dropFirst(before)
    #expect(!later.contains { $0.contains("create-keychain") } && f.lines(starting: "create-keychain").count == 1)
    #expect(!later.contains { $0.first == "openssl" })
    #expect(f.lines(starting: "unlock-keychain").count >= 2)
  }

  @Test func adoptsAnIntactKeychainWhoseRecordsWereLost() async throws {
    var state = KeychainWorld.State()
    state.password = "feedface"
    state.identities = [KeychainWorld.newSHA1]
    let f = try fixture(state)
    try FileManager.default.createDirectory(at: f.paths.signingDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: f.keychain.path, contents: Data())
    try Data("feedface\n".utf8).write(to: f.passwordFile)
    let identity = try await f.provisioner.ensureIdentity()
    #expect(identity == .certificate(sha1: KeychainWorld.newSHA1, keychain: f.keychain))
    #expect(f.lines(starting: "create-keychain").isEmpty)
    #expect(await f.settings.signingKeychainPath == f.keychain.path)
    #expect(FileManager.default.fileExists(atPath: f.paths.identityFile.path))
  }

  @Test func keepsTheAuthorsLoginKeychainIdentity() async throws {
    var state = KeychainWorld.State()
    state.loginIdentities = [testSHA1]
    let f = try fixture(state)
    try installIdentity(f.paths)
    #expect(try await f.provisioner.ensureIdentity() == .certificate(sha1: testSHA1, keychain: nil))
    #expect(f.interactiveLines.isEmpty)
    #expect(!f.runner.commandLines.contains { $0.first == "openssl" })
  }

  @Test func neverReplacesAMissingLoginKeychainIdentity() async throws {
    let f = try fixture()
    try installIdentity(f.paths)
    await #expect(throws: SigningKeychainError.recordedIdentityMissing(testSHA1)) {
      _ = try await f.provisioner.ensureIdentity()
    }
    #expect(f.interactiveLines.isEmpty)
    #expect(await f.settings.signingIdentitySHA1 == testSHA1)
  }

  @Test func unusableKeychainIsSetAsideNotDeleted() async throws {
    let f = try fixture()
    try FileManager.default.createDirectory(at: f.paths.signingDir, withIntermediateDirectories: true)
    try Data("old keychain".utf8).write(to: f.keychain)
    try Data("lost".utf8).write(to: f.passwordFile)
    let identity = try await f.provisioner.ensureIdentity()
    #expect(identity == .certificate(sha1: KeychainWorld.newSHA1, keychain: f.keychain))
    let names = try FileManager.default.contentsOfDirectory(atPath: f.paths.signingDir.path)
    let staleKeychain = try #require(names.first { $0.hasPrefix("cmacc-signing.keychain-db.stale-") })
    let stalePassword = try #require(names.first { $0.hasPrefix("keychain-password.stale-") })
    #expect(try Data(contentsOf: f.paths.signingDir.appendingPathComponent(staleKeychain)) == Data("old keychain".utf8))
    #expect(try Data(contentsOf: f.paths.signingDir.appendingPathComponent(stalePassword)) == Data("lost".utf8))
    #expect(!f.runner.commandLines.contains { $0.contains("delete-keychain") })
  }

  /// A busy Mac (unlock timed out) must not cost the identity: the keychain stays, nothing new is created.
  @Test func transientUnlockFailureNeverSetsTheKeychainAside() async throws {
    var state = KeychainWorld.State()
    state.password = "feedface"
    state.identities = [KeychainWorld.newSHA1]
    state.unlockTimesOut = true
    let f = try fixture(state)
    try FileManager.default.createDirectory(at: f.paths.signingDir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: f.keychain.path, contents: Data("intact".utf8))
    try Data("feedface\n".utf8).write(to: f.passwordFile)
    await #expect(throws: BuilderError.commandTimedOut("security")) { _ = try await f.provisioner.ensureIdentity() }
    #expect(try Data(contentsOf: f.keychain) == Data("intact".utf8))
    #expect(FileManager.default.fileExists(atPath: f.passwordFile.path))
    let names = try FileManager.default.contentsOfDirectory(atPath: f.paths.signingDir.path)
    #expect(!names.contains { $0.contains(".stale-") })
    #expect(f.lines(starting: "create-keychain").isEmpty && !f.runner.commandLines.contains { $0.first == "openssl" })
  }

  @Test func searchListChangeDeletesTheNewKeychainAgain() async throws {
    var state = KeychainWorld.State()
    state.searchListAfterCreate = "    \"/Users/u/Library/Keychains/login.keychain-db\"\n    \"/x/cmacc-signing.keychain-db\"\n"
    let f = try fixture(state)
    await #expect(throws: SigningKeychainError.searchListChanged) { _ = try await f.provisioner.ensureIdentity() }
    #expect(f.runner.commandLines.contains(["security", "delete-keychain", f.keychain.path]))
    #expect(!FileManager.default.fileExists(atPath: f.passwordFile.path))
    #expect(await f.settings.signingIdentitySHA1 == nil)
  }

  @Test func failedImportDiscardsEverythingAndRedactsSecrets() async throws {
    let f = try fixture()
    let leaked = f.world
    // The fake echoes the p12 password into stderr; the error must not carry it.
    let echoing = ScriptedRunner { request in
      if request.arguments == ["-i"], String(decoding: request.stdin ?? Data(), as: UTF8.self).hasPrefix("import ") {
        let p12 = leaked.state.withLock { $0.p12Password } ?? "?"
        return .fail(1, stderr: "security: SecKeychainItemImport: bad password \(p12)")
      }
      return try leaked.runner.responder(request)
    }
    let provisioner = SigningIdentityProvisioner(paths: f.paths, runner: echoing, clock: FixedClock(now: Date()))
    await #expect(throws: SigningKeychainError.commandFailed(
      step: "import", stderr: "security: SecKeychainItemImport: bad password <secret>")) {
      _ = try await provisioner.ensureIdentity()
    }
    #expect(echoing.commandLines.contains(["security", "delete-keychain", f.keychain.path]))
    #expect(!FileManager.default.fileExists(atPath: f.passwordFile.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.signingDir.path).allSatisfy { !$0.hasPrefix(".provision-") })
    #expect(await f.settings.signingIdentitySHA1 == nil)
  }

  private func workDirName(_ f: Fixture) -> String? {
    f.runner.recorded.first { $0.arguments.first == "req" }?.arguments
      .first { $0.hasSuffix("/key.pem") }
      .map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }
  }
}

@Suite struct SigningIdentityCheckTests {
  @Test func dedicatedKeychainIsCheckedFirstAndUnlockedBeforeLooking() async throws {
    let root = try makeTempDir()
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"))
    let keychain = paths.signingDir.appendingPathComponent("cmacc-signing.keychain-db")
    try installIdentity(paths)
    try Data("{\"builder\":{\"signingIdentitySHA1\":\"\(testSHA1)\",\"signingKeychainPath\":\"\(keychain.path)\"}}".utf8)
      .write(to: paths.settingsFile)
    FileManager.default.createFile(atPath: keychain.path, contents: Data())
    try Data("pw".utf8).write(to: paths.signingDir.appendingPathComponent("keychain-password"))
    var state = KeychainWorld.State()
    state.password = "pw"
    state.identities = [testSHA1]
    let world = KeychainWorld(state)
    let runner = world.runner
    let check = SigningIdentityCheck(paths: paths, runner: runner)
    #expect(await check.permanentIdentity() == .certificate(sha1: testSHA1, keychain: keychain))
    #expect(runner.commandLines.map { $0.prefix(2).joined(separator: " ") } == ["security -i", "security find-identity"])
    #expect(!runner.commandLines.contains { $0.contains("find-certificate") })
  }

  @Test func fallsBackToTheSearchListAndReportsBothPlaces() async throws {
    let root = try makeTempDir()
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"))
    try installIdentity(paths)
    let keychain = paths.signingDir.appendingPathComponent("gone.keychain-db")
    try Data("{\"builder\":{\"signingIdentitySHA1\":\"\(testSHA1)\",\"signingKeychainPath\":\"\(keychain.path)\"}}".utf8)
      .write(to: paths.settingsFile)
    let missing = await SigningIdentityCheck(paths: paths, runner: KeychainWorld().runner).evaluate()
    #expect(!missing.passed)
    #expect(missing.detail.contains("gone.keychain-db or the keychain search list"))
    var state = KeychainWorld.State()
    state.loginIdentities = [testSHA1]
    let found = await SigningIdentityCheck(paths: paths, runner: KeychainWorld(state).runner).evaluate()
    #expect(found.passed && found.keychain == nil)
  }

  @Test func parsesFindIdentityOutput() {
    let output = """

      Policy: Code Signing
        Matching identities
        1) 95A2CAF09C7A21B5719D177649AC0C708F427321 "ClaudeMultiAcc Local Signing" (CSSMERR_TP_NOT_TRUSTED)
        2) 1111111111111111111111111111111111111111 "Other Signing" (CSSMERR_TP_NOT_TRUSTED)
           2 identities found

        Valid identities only
           0 valid identities found
      """
    #expect(SigningIdentityCheck.identities(in: output) == ["95A2CAF09C7A21B5719D177649AC0C708F427321"])
    #expect(SigningIdentityCheck.identities(in: "0 identities found").isEmpty)
  }
}

/// Never the login keychain, the search list (`-s`), the default keychain or trust settings.
func expectNoForbiddenKeychainCommands(_ runner: ScriptedRunner, sourceLocation: SourceLocation = #_sourceLocation) {
  let texts = runner.recorded.map { ($0.arguments + [String(decoding: $0.stdin ?? Data(), as: UTF8.self)]).joined(separator: " ") }
  for text in texts {
    for forbidden in ["login.keychain-db\" -", "list-keychains -d user -s", "default-keychain", "add-trusted-cert",
                      "trust-settings", "login-keychain"] {
      #expect(!text.contains(forbidden), "forbidden: \(text)", sourceLocation: sourceLocation)
    }
  }
  #expect(!runner.recorded.contains { $0.arguments.contains("-s") && $0.arguments.first == "list-keychains" },
          sourceLocation: sourceLocation)
}

func posixMode(_ url: URL) throws -> Int {
  try ((FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue) ?? -1
}
