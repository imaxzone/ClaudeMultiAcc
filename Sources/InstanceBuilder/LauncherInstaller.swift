import Foundation
import Support

/// Contents of `Contents/Resources/ClaudeMultiAcc-launcher.json`, read by the CloneLauncher executable.
/// The schema is mirrored by `CloneLauncher/LauncherConfig.swift`; both are covered by tests on the same JSON.
public struct LauncherConfigFile: Codable, Sendable, Equatable {
  public static let fileName = "ClaudeMultiAcc-launcher.json"
  public static let realExecutable = "Claude.real"

  public let schemaVersion: Int
  public let slug: String
  public let bundleId: String
  public let profileDir: String
  public let realExecutable: String
  public let logFile: String

  public init(spec: CloneSpec, logsDir: URL) {
    schemaVersion = 1
    slug = spec.slug.raw
    bundleId = spec.bundleId
    profileDir = spec.profileDir.path
    realExecutable = Self.realExecutable
    logFile = logsDir.appendingPathComponent("launcher-\(spec.slug.raw).log").path
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  /// Whether this config launches `spec` (slug, bundle id, profile and the fixed real executable name).
  public func matches(_ spec: CloneSpec) -> Bool {
    schemaVersion == 1 && slug == spec.slug.raw && bundleId == spec.bundleId && profileDir == spec.profileDir.path
      && realExecutable == Self.realExecutable
  }
}

/// Step 7: moves Electron's `Contents/MacOS/Claude` to `Claude.real` and puts the compiled launcher in its place (D6),
/// without the launcher's quarantine attribute.
public struct LauncherInstaller: Sendable {
  public init() {}

  public func install(into app: URL, spec: CloneSpec, launcherBinary: URL, logsDir: URL) throws {
    let fm = FileManager.default
    guard fm.isExecutableFile(atPath: launcherBinary.path) else { throw BuilderError.launcherMissing(launcherBinary.path) }
    let macOS = app.appendingPathComponent("Contents/MacOS")
    let main = macOS.appendingPathComponent("Claude")
    try fm.moveItem(at: main, to: macOS.appendingPathComponent(LauncherConfigFile.realExecutable))
    try fm.copyItem(at: launcherBinary, to: main)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path)
    let config = app.appendingPathComponent("Contents/Resources/\(LauncherConfigFile.fileName)")
    try LauncherConfigFile(spec: spec, logsDir: logsDir).encoded().write(to: config)
    // The copy keeps the launcher's `com.apple.quarantine` (a downloaded ClaudeMultiAcc.app) and `clean` already ran.
    try Quarantine.remove(from: main)
    try Quarantine.remove(from: config)
  }
}
