import AppKit
import Foundation
import Support

public protocol RunningChecking: Sendable {
  func isRunning(bundleId: String, profileDir: URL?) async -> Bool
}

/// Whether an app runs (G9): `NSRunningApplication` by bundle id, `lsappinfo find bundleid=<id>`, and the
/// clone's `<profile>/.clone.lock` held by a launcher. Never `pgrep`.
public struct RunningCheck: RunningChecking {
  private let runner: ProcessRunning
  private let runningAppURLs: @Sendable (String) -> [URL]

  public init(runner: ProcessRunning, runningAppURLs: @escaping @Sendable (String) -> [URL] = RunningCheck.workspaceAppURLs) {
    self.runner = runner
    self.runningAppURLs = runningAppURLs
  }

  /// Bundle URLs of the running apps with this bundle id (`NSRunningApplication`).
  public static func workspaceAppURLs(_ bundleId: String) -> [URL] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).compactMap(\.bundleURL)
  }

  /// Whether the app at exactly `app` runs, not merely some copy with the same bundle id (a stray copy in
  /// Downloads or on a mounted DMG). `NSRunningApplication` bundle URLs first, then each `lsappinfo find` ASN whose
  /// `bundle path` is `app`. Symlinks are resolved on both sides; anything unreadable counts as not running.
  public func isRunning(bundleId: String, at app: URL) async -> Bool {
    let target = Self.resolvedPath(app)
    if runningAppURLs(bundleId).contains(where: { Self.resolvedPath($0) == target }) { return true }
    let found = try? await runner.runTool(BuilderTool.lsappinfo, ["find", "bundleid=\(bundleId)"], timeout: BuilderTool.shortTimeout)
    guard let found, found.exitCode == 0 else { return false }
    for asn in Self.asns(in: found.stdoutText) {
      let info = try? await runner.runTool(
        BuilderTool.lsappinfo, ["info", "-only", "bundlepath", asn], timeout: BuilderTool.shortTimeout)
      guard let info, info.exitCode == 0, let path = Self.bundlePath(in: info.stdoutText) else { continue }
      if Self.resolvedPath(URL(fileURLWithPath: path)) == target { return true }
    }
    return false
  }

  static func resolvedPath(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// `ASN:0x0-0x8b08b-"Claude":` → `ASN:0x0-0x8b08b:` (the name may contain spaces, so it is dropped).
  static func asns(in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: "ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+") else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { text[$0] + ":" } }
  }

  /// `bundle path="/Applications/Claude.app"` (or `"LSBundlePath"="…"`) from `lsappinfo info`.
  static func bundlePath(in text: String) -> String? {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      for prefix in ["bundle path=\"", "\"LSBundlePath\"=\""] where trimmed.hasPrefix(prefix) && trimmed.hasSuffix("\"") {
        let path = trimmed.dropFirst(prefix.count).dropLast()
        return path.isEmpty ? nil : String(path)
      }
    }
    return nil
  }

  public func isRunning(bundleId: String) async -> Bool {
    await isRunning(bundleId: bundleId, profileDir: nil)
  }

  public func isRunning(bundleId: String, profileDir: URL?) async -> Bool {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty { return true }
    if let profileDir, Self.isLockHeld(profileDir.appendingPathComponent(".clone.lock")) { return true }
    let result = try? await runner.runTool(BuilderTool.lsappinfo, ["find", "bundleid=\(bundleId)"], timeout: BuilderTool.shortTimeout)
    guard let result, result.exitCode == 0 else { return false }
    return !result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Probes an existing lock file with a shared non-blocking flock; never creates the file.
  static func isLockHeld(_ lock: URL) -> Bool {
    let fd = open(lock.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_SH | LOCK_NB) == 0 {
      flock(fd, LOCK_UN)
      return false
    }
    return errno == EWOULDBLOCK
  }
}
