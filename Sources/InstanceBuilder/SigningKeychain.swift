import Foundation
import Support

public enum SigningKeychainError: Error, Equatable {
  /// A value `security -i` cannot quote (contains `"`, a backslash or a line break). The value is not carried: it can
  /// be a password.
  case unquotable
  case passwordMissing(String)
  case unlockFailed(String)
  case commandFailed(step: String, stderr: String)
  case identityNotFound(String)
  /// The user keychain search list changed while the keychain was created; the new keychain was deleted again.
  case searchListChanged
  /// settings.json records a login-keychain identity (`signing-setup.sh`) that is gone; it is never replaced silently.
  case recordedIdentityMissing(String)
  case lockUnavailable

  public var userMessage: String {
    switch self {
    case .recordedIdentityMissing: BuilderText.string("signing.recorded-missing")
    case .unlockFailed, .passwordMissing: BuilderText.string("signing.unlock-failed")
    case .lockUnavailable: BuilderText.string("signing.lock-unavailable")
    case .unquotable, .commandFailed, .identityNotFound, .searchListChanged: BuilderText.string("signing.create-failed")
    }
  }
}

/// A dedicated keychain file whose random password is stored beside it in `keychain-password` (0600), as made by
/// `SigningIdentityProvisioner`. It is never added to the keychain search list.
public struct SigningKeychain: Sendable, Equatable {
  public static let passwordFileName = "keychain-password"
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public var passwordFile: URL { url.deletingLastPathComponent().appendingPathComponent(Self.passwordFileName) }
  public var hasStoredPassword: Bool { FileManager.default.fileExists(atPath: passwordFile.path) }

  func storedPassword() -> String? {
    guard let data = FileManager.default.contents(atPath: passwordFile.path) else { return nil }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// `security -i` with `unlock-keychain -p … <keychain>` on stdin, so the password never appears in argv or `ps`.
  public func unlock(runner: ProcessRunning) async throws {
    guard let password = storedPassword() else { throw SigningKeychainError.passwordMissing(passwordFile.path) }
    let line = "unlock-keychain -p \(try Self.quoted(password)) \(try Self.quoted(url.path))"
    try await Self.interactive(runner, line, secrets: [password]) { SigningKeychainError.unlockFailed($0) }
  }

  /// Runs ONE command read by `security -i` from stdin (its exit status is that of the last command only).
  /// Secrets are removed from the stderr carried by the error.
  @discardableResult
  static func interactive(
    _ runner: ProcessRunning, _ line: String, secrets: [String], failure: (String) -> SigningKeychainError
  ) async throws -> ProcessResult {
    let request = ProcessRequest(
      executable: BuilderTool.security, arguments: ["-i"], timeout: BuilderTool.shortTimeout, stdin: Data((line + "\n").utf8))
    let result = try await runner.run(request)
    if result.timedOut { throw BuilderError.commandTimedOut(BuilderTool.security.lastPathComponent) }
    guard result.exitCode == 0 else {
      var stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
      for secret in secrets where !secret.isEmpty { stderr = stderr.replacingOccurrences(of: secret, with: "<secret>") }
      throw failure(stderr)
    }
    return result
  }

  /// A double-quoted `security -i` argument; values it could not parse back are refused.
  static func quoted(_ value: String) throws -> String {
    guard !value.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
      throw SigningKeychainError.unquotable
    }
    return "\"\(value)\""
  }
}
