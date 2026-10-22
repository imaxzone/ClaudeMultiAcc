import Foundation
import os
import Support

public enum SigningIdentityError: Error, Equatable {
  case invalid(String)
  case keychainWithoutCertificate
}

/// `adhoc` (`--sign -`) or a certificate by SHA-1, optionally from an explicit keychain file (G10).
public enum SigningIdentity: Sendable, Equatable {
  case adhoc
  case certificate(sha1: String, keychain: URL?)

  /// `"adhoc"`/`"-"` or a 40-hex SHA-1 (normalised to upper case). A keychain requires a certificate.
  public static func parse(_ text: String, keychain: URL?) throws -> SigningIdentity {
    if text == "adhoc" || text == "-" {
      guard keychain == nil else { throw SigningIdentityError.keychainWithoutCertificate }
      return .adhoc
    }
    let isHex = text.count == 40 && text.allSatisfy(\.isHexDigit)
    guard isHex else { throw SigningIdentityError.invalid(text) }
    return .certificate(sha1: text.uppercased(), keychain: keychain)
  }

  public var kind: String {
    switch self {
    case .adhoc: "adhoc"
    case .certificate: "certificate"
    }
  }

  var signArguments: [String] {
    switch self {
    case .adhoc: ["--sign", "-"]
    case .certificate(let sha1, let keychain): ["--sign", sha1] + (keychain.map { ["--keychain", $0.path] } ?? [])
    }
  }
}

/// Signs a staged clone inside-out without `--deep` (G10): `Claude.real`, then the outer bundle.
/// Nothing under `Contents/Frameworks` is ever re-signed: the vendor helpers load those frameworks with library
/// validation and reject any whose Team ID differs from theirs (see `VendorFrameworksCheck`).
public struct Signer: Sendable {
  private let runner: ProcessRunning
  private let log = AppLog.logger("signer")

  public init(runner: ProcessRunning) {
    self.runner = runner
  }

  /// Returns the command lines that ran, with the keychain path replaced by `<keychain>`.
  public func sign(app: URL, spec: CloneSpec, entitlements: URL, identity: SigningIdentity) async throws -> [String] {
    let base = ["--force", "--timestamp=none"] + identity.signArguments
    let hardened = ["--options", "runtime"]
    let withIdentity = hardened + ["-i", spec.bundleId, "--entitlements", entitlements.path]
    let steps = [
      base + withIdentity + [app.appendingPathComponent("Contents/MacOS/Claude.real").path],
      base + withIdentity + [app.path],
    ]

    var ran: [String] = []
    for arguments in steps {
      let line = redacted(["codesign"] + arguments, identity: identity)
      log.info("\(line, privacy: .public)")
      try await unlockDedicatedKeychain(of: identity)
      try await runner.runChecked(BuilderTool.codesign, arguments, timeout: BuilderTool.signTimeout)
      ran.append(line)
    }
    return ran
  }

  /// codesign on a LOCKED keychain makes macOS ask the user for that keychain's password (a random one they never
  /// saw), so a keychain with a stored password (`SigningKeychain`) is unlocked right before every codesign run; a
  /// failed unlock, or the app's own keychain without its password, stops before codesign. Other keychains without
  /// one are managed by the caller (`make-test-identity.sh`).
  private func unlockDedicatedKeychain(of identity: SigningIdentity) async throws {
    guard case .certificate(_, let url?) = identity else { return }
    let keychain = SigningKeychain(url: url)
    guard keychain.hasStoredPassword || url.lastPathComponent == SigningIdentityProvisioner.keychainFileName else { return }
    try await keychain.unlock(runner: runner)
  }

  /// The designated requirement from `codesign -d -r-` (the text after `designated => `).
  public func designatedRequirement(app: URL) async throws -> String {
    let result = try await runner.runChecked(BuilderTool.codesign, ["-d", "-r-", app.path], timeout: BuilderTool.shortTimeout)
    let lines = (result.stdoutText + "\n" + result.stderrText).split(separator: "\n")
    // Ad hoc signatures print an implicit requirement as a comment: `# designated => cdhash H"…"`.
    for prefix in ["designated => ", "# designated => "] {
      if let line = lines.first(where: { $0.hasPrefix(prefix) }) {
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      }
    }
    throw BuilderError.noDesignatedRequirement
  }

  private func redacted(_ arguments: [String], identity: SigningIdentity) -> String {
    guard case .certificate(_, let keychain?) = identity else { return arguments.joined(separator: " ") }
    return arguments.map { $0 == keychain.path ? "<keychain>" : $0 }.joined(separator: " ")
  }
}
