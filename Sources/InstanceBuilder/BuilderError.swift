import Foundation

/// Every failure of the clone builder. Messages for logs are English (G8); the UI maps cases to text in the UI
/// language.
public enum BuilderError: Error, Equatable, Sendable {
  // Spec / registry
  case notAClone(String)
  case incompleteInstance(String)
  case vendorBundleId(String)
  case invalidDisplayName(String)
  // Plist / entitlements
  case invalidPlist(String)
  case unexpectedBundleName(String)
  case forbiddenEntitlement(String)
  // Preflight
  case targetRunning(String)
  case vendorUpdateActive
  case insufficientSpace(availableBytes: Int64)
  // Source
  case unexpectedSourceBundleId(String)
  case unexpectedTeamId(expected: String, found: String)
  case sourceSignatureInvalid(String)
  case sourceUnreadable(String)
  case sourceChangedDuringCopy
  // Steps
  case commandFailed(tool: String, exitCode: Int32, stderr: String)
  case commandTimedOut(String)
  case launcherMissing(String)
  case noDesignatedRequirement
  case verificationFailed([String])
  case smokeFailed([String])
  // Staging
  case buildDirExists(String)
  case stagingPathRefused(String)
}

extension BuilderError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notAClone(let slug): "instance '\(slug)' is not a clone"
    case .incompleteInstance(let slug): "instance '\(slug)' lacks a bundle id or profile dir"
    case .vendorBundleId(let id): "refusing vendor bundle id '\(id)'"
    case .invalidDisplayName(let name): "invalid display name '\(name)'"
    case .invalidPlist(let what): "invalid property list: \(what)"
    case .unexpectedBundleName(let name): "CFBundleName is '\(name)', expected 'Claude'"
    case .forbiddenEntitlement(let key): "forbidden entitlement '\(key)'"
    case .targetRunning(let id): "an app with bundle id '\(id)' is running"
    case .vendorUpdateActive: "the official Claude is being updated right now (ShipIt is installing)"
    case .insufficientSpace(let bytes): "not enough free space (\(bytes) bytes available, 2 GB required)"
    case .unexpectedSourceBundleId(let id): "source bundle id is '\(id)'"
    case .unexpectedTeamId(let expected, let found): "source team id is '\(found)', expected '\(expected)'"
    case .sourceSignatureInvalid(let detail): "source signature invalid: \(detail)"
    case .sourceUnreadable(let path): "cannot read source at \(path)"
    case .sourceChangedDuringCopy: "the source app changed while it was being copied"
    case .commandFailed(let tool, let code, let stderr): "\(tool) failed (\(code)): \(stderr)"
    case .commandTimedOut(let tool): "\(tool) timed out"
    case .launcherMissing(let path): "launcher binary missing at \(path)"
    case .noDesignatedRequirement: "no designated requirement in codesign output"
    case .verificationFailed(let names): "signature verification failed: \(names.joined(separator: ", "))"
    case .smokeFailed(let names): "static smoke checks failed: \(names.joined(separator: ", "))"
    case .buildDirExists(let path): "build dir already exists: \(path)"
    case .stagingPathRefused(let path): "refusing to touch \(path): not a real directory inside staging"
    }
  }
}
