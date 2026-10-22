import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// `scripts/signing-setup.sh --record-only`: writes identity.json and settings.json from an existing cert.pem.
/// Hermetic: a throwaway certificate in a temp data dir; the keychain is never touched.
@Suite struct SigningSetupScriptTests {
  let runner = SystemProcessRunner()
  static let script = Repo.root.appendingPathComponent("scripts/signing-setup.sh")
  static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")

  /// A temp data dir with `signing/cert.pem`; returns the dir and the certificate's SHA-1 (upper-case hex).
  private func makeDataDir(_ name: String = #function) async throws -> (dir: URL, sha1: String) {
    let dir = try makeTempDir(name)
    let signing = dir.appendingPathComponent("signing", isDirectory: true)
    try FileManager.default.createDirectory(at: signing, withIntermediateDirectories: true)
    let cert = signing.appendingPathComponent("cert.pem")
    let made = try await runner.run(ProcessRequest(
      executable: Self.openssl,
      arguments: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=cmacc test",
                  "-keyout", dir.appendingPathComponent("key.pem").path, "-out", cert.path],
      timeout: .seconds(60)))
    try #require(made.exitCode == 0, "openssl req: \(made.stderrText)")
    let print = try await runner.run(ProcessRequest(
      executable: Self.openssl, arguments: ["x509", "-in", cert.path, "-noout", "-fingerprint", "-sha1"],
      timeout: .seconds(30)))
    let sha1 = print.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: "=").last?.replacingOccurrences(of: ":", with: "") ?? ""
    try #require(sha1.count == 40)
    return (dir, sha1)
  }

  private func recordOnly(dataDir: URL) async throws -> ProcessResult {
    var env = ProcessInfo.processInfo.environment
    env["CMACC_DATA_DIR"] = dataDir.path
    return try await runner.run(ProcessRequest(
      executable: Self.script, arguments: ["--record-only"], environment: env, timeout: .seconds(60)))
  }

  private func mode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }

  /// The bare `{}` case is the one that broke the first real run: plutil takes `{}` for an old-style plist.
  @Test(arguments: [nil, "", "{}", "{}\n", "{ }\n"] as [String?])
  func recordsIntoAMissingOrEmptySettingsFile(initial: String?) async throws {
    let (dir, sha1) = try await makeDataDir()
    let settings = dir.appendingPathComponent("settings.json")
    if let initial { try Data(initial.utf8).write(to: settings) }

    let result = try await recordOnly(dataDir: dir)

    #expect(result.exitCode == 0, "\(result.stderrText)")
    let loaded = try await SettingsStore(file: settings).loadStrict()
    #expect(loaded.builder.signingIdentitySHA1 == sha1)
    #expect(loaded.builder.neutralizeUpdater == AppSettings.defaults.builder.neutralizeUpdater)
    #expect(try mode(settings) == 0o600)
  }

  @Test func keepsTheOtherSettingsWhenTheBuilderSectionIsMissing() async throws {
    let (dir, sha1) = try await makeDataDir()
    let settings = dir.appendingPathComponent("settings.json")
    try Data(#"{"schemaVersion":1,"updates":{"autoRebuild":false}}"#.utf8).write(to: settings)

    let result = try await recordOnly(dataDir: dir)

    #expect(result.exitCode == 0, "\(result.stderrText)")
    let loaded = try await SettingsStore(file: settings).loadStrict()
    #expect(loaded.builder.signingIdentitySHA1 == sha1)
    #expect(loaded.updates.autoRebuild == false)
  }

  @Test func keepsTheRestOfAnExistingBuilderSection() async throws {
    let (dir, sha1) = try await makeDataDir()
    let settings = dir.appendingPathComponent("settings.json")
    try Data(#"{"builder":{"neutralizeUpdater":false,"signingIdentitySHA1":"OLD"}}"#.utf8).write(to: settings)

    let result = try await recordOnly(dataDir: dir)

    #expect(result.exitCode == 0, "\(result.stderrText)")
    let loaded = try await SettingsStore(file: settings).loadStrict()
    #expect(loaded.builder.signingIdentitySHA1 == sha1)
    #expect(loaded.builder.neutralizeUpdater == false)
  }

  @Test func writesIdentityJsonWithTheCertificateFingerprint() async throws {
    let (dir, sha1) = try await makeDataDir()

    let result = try await recordOnly(dataDir: dir)

    #expect(result.exitCode == 0, "\(result.stderrText)")
    let identity = dir.appendingPathComponent("signing/identity.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: identity)) as? [String: String]
    #expect(json?["sha1"] == sha1)
    #expect(json?["commonName"] == "ClaudeMultiAcc Local Signing")
    #expect(try mode(identity) == 0o600)
    #expect(result.stdoutText.contains(sha1))
  }

  @Test func refusesWithoutACertificateAndWritesNothing() async throws {
    let dir = try makeTempDir()

    let result = try await recordOnly(dataDir: dir)

    #expect(result.exitCode == 1)
    #expect(result.stderrText.contains("cert.pem"))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("settings.json").path))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("signing/identity.json").path))
  }
}
