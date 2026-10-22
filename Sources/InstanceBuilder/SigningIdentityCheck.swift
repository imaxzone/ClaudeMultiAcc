import Foundation
import Support

/// Whether the permanent local signing identity is set up: `builder.signingIdentitySHA1` in settings,
/// `signing/identity.json`, and the certificate found first in the dedicated keychain `builder.signingKeychainPath`
/// (made by `SigningIdentityProvisioner`; unlocked with its stored password to look inside), else in the default
/// keychain search list (the author's login-keychain identity from `scripts/signing-setup.sh`, read-only).
public struct SigningIdentityCheck: Sendable {
  public static let commonName = "ClaudeMultiAcc Local Signing"

  public struct Status: Sendable, Equatable {
    public let sha1: String?
    /// The dedicated keychain holding the identity; `nil` for the default search list.
    public let keychain: URL?
    public let passed: Bool
    public let detail: String

    public init(sha1: String?, keychain: URL? = nil, passed: Bool, detail: String) {
      self.sha1 = sha1
      self.keychain = keychain
      self.passed = passed
      self.detail = detail
    }
  }

  private let paths: Paths
  private let runner: ProcessRunning

  public init(paths: Paths, runner: ProcessRunning) {
    self.paths = paths
    self.runner = runner
  }

  public func evaluate() async -> Status {
    let builder = await SettingsStore(file: paths.settingsFile).load().builder
    guard let sha1 = builder.signingIdentitySHA1?.uppercased(), !sha1.isEmpty else {
      return Status(sha1: nil, passed: false, detail: "builder.signingIdentitySHA1 not set — \(SigningSetup.hint)")
    }
    guard FileManager.default.fileExists(atPath: paths.identityFile.path) else {
      return Status(sha1: sha1, passed: false, detail: "\(paths.identityFile.lastPathComponent) missing")
    }
    let dedicated = builder.signingKeychainPath.flatMap { $0.isEmpty ? nil : SigningKeychain(url: URL(fileURLWithPath: $0)) }
    if let dedicated, await Self.identityHashes(in: dedicated, runner: runner).contains(sha1) {
      return Status(sha1: sha1, keychain: dedicated.url, passed: true,
                    detail: "\"\(Self.commonName)\" \(sha1) in \(dedicated.url.lastPathComponent)")
    }
    guard await listedHashes().contains(sha1) else {
      let place = dedicated.map { "\($0.url.lastPathComponent) or the keychain search list" } ?? "the keychain search list"
      return Status(sha1: sha1, passed: false, detail: "\"\(Self.commonName)\" \(sha1) not found in \(place)")
    }
    return Status(sha1: sha1, passed: true, detail: "\"\(Self.commonName)\" \(sha1)")
  }

  /// The permanent identity when every part of the check passes, with its dedicated keychain if it has one.
  public func permanentIdentity() async -> SigningIdentity? {
    let status = await evaluate()
    guard status.passed, let sha1 = status.sha1 else { return nil }
    return .certificate(sha1: sha1, keychain: status.keychain)
  }

  /// SHA-1 hashes printed by `security find-certificate -c <CN> -Z` (default search list, read-only).
  private func listedHashes() async -> Set<String> {
    let result = try? await runner.runTool(
      BuilderTool.security, ["find-certificate", "-a", "-c", Self.commonName, "-Z"], timeout: BuilderTool.shortTimeout)
    guard let result, result.exitCode == 0 else { return [] }
    return Self.hashes(in: result.stdoutText)
  }

  static func hashes(in output: String) -> Set<String> {
    let prefix = "SHA-1 hash:"
    return Set(output.split(separator: "\n").compactMap { line -> String? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix(prefix) else { return nil }
      return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).uppercased()
    })
  }

  /// Code-signing identities named `commonName` in a dedicated keychain (certificate AND private key). The keychain is
  /// unlocked first: a locked one lists nothing, and codesign on it would ask the user for its password. Empty when the
  /// file, its password or the unlock is missing.
  static func identityHashes(in keychain: SigningKeychain, runner: ProcessRunning) async -> Set<String> {
    guard FileManager.default.fileExists(atPath: keychain.url.path), keychain.hasStoredPassword else { return [] }
    guard (try? await keychain.unlock(runner: runner)) != nil else { return [] }
    let result = try? await runner.runTool(
      BuilderTool.security, ["find-identity", "-p", "codesigning", keychain.url.path], timeout: BuilderTool.shortTimeout)
    guard let result, result.exitCode == 0 else { return [] }
    return identities(in: result.stdoutText)
  }

  /// `  1) <SHA-1> "<name>" (CSSMERR_TP_NOT_TRUSTED)` lines of `find-identity`; the self-signed certificate is
  /// untrusted, so it appears under "Matching identities" only — which is all codesign needs (experiment E2).
  static func identities(in output: String) -> Set<String> {
    let line = /^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]*)"/
    return Set(output.split(separator: "\n").compactMap { text -> String? in
      guard let match = text.firstMatch(of: line), match.2 == commonName else { return nil }
      return String(match.1).uppercased()
    })
  }
}
