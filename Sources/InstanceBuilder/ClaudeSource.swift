import Foundation
import Support

/// A Claude.app clones can be built from: the official `/Applications/Claude.app` or a version ClaudeMultiAcc
/// downloaded and verified itself.
public struct ClaudeSource: Sendable, Equatable {
  public let app: URL
  public let version: String
  public let isOfficial: Bool

  public init(app: URL, version: String, isOfficial: Bool) {
    self.app = app
    self.version = version
    self.isOfficial = isOfficial
  }
}

/// The downloaded Claude versions under `<data>/source/` (`<version>.noindex/Claude.app`; `.noindex` keeps Spotlight
/// out) and the choice of the newest source. Without the official app there is no source at all: clones then behave as
/// before downloads existed. A download only counts while it is strictly newer than the official app.
public struct ClaudeSourceStore: Sendable {
  static let slotSuffix = ".noindex"
  static let appName = "Claude.app"

  public let paths: Paths
  public let officialApp: URL

  public init(paths: Paths, officialApp: URL = ClonePathPolicy.vendorApp) {
    self.paths = paths
    self.officialApp = officialApp
  }

  public var root: URL { paths.claudeSourcesDir }
  /// Where a download is unpacked and checked before it moves into its slot; wiped before and after every download.
  public var incomingDir: URL { root.appendingPathComponent("incoming" + Self.slotSuffix, isDirectory: true) }

  /// `<root>/<version>.noindex`; `version` must pass `isValidVersion`.
  public func slot(for version: String) -> URL {
    precondition(Self.isValidVersion(version), "invalid Claude version \(version)")
    return root.appendingPathComponent(version + Self.slotSuffix, isDirectory: true)
  }

  /// Two to four numeric parts of up to six digits (`3.1623.3`): safe as a folder name and comparable.
  public static func isValidVersion(_ version: String) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...4).contains(parts.count) else { return false }
    return parts.allSatisfy { part in (1...6).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } }
  }

  /// The official app with its version; nil when it is missing or its version is unreadable.
  public func official() -> ClaudeSource? {
    guard let version = AppVersion.read(officialApp) else { return nil }
    return ClaudeSource(app: officialApp, version: version, isOfficial: true)
  }

  /// The newest slot whose `Claude.app` is the vendor app of exactly the slot's version.
  public func downloaded() -> ClaudeSource? {
    slots().compactMap { version, dir -> ClaudeSource? in
      let app = dir.appendingPathComponent(Self.appName, isDirectory: true)
      guard Self.isRealDirectory(app), Self.bundleId(of: app) == CloneSpec.vendorBundleId,
            AppVersion.read(app) == version
      else { return nil }
      return ClaudeSource(app: app, version: version, isOfficial: false)
    }
    .max { VersionCompare.isNewer($1.version, than: $0.version) }
  }

  /// What every build uses: the download when it is strictly newer than the official app, otherwise the official app;
  /// nil without the official app.
  public func newest() -> ClaudeSource? {
    guard let official = official() else { return nil }
    guard let download = downloaded(), VersionCompare.isNewer(download.version, than: official.version) else {
      return official
    }
    return download
  }

  /// Removes every slot except `version`'s (all of them for nil); returns what was removed. Only real directories
  /// directly inside `root` are touched; a symlink is removed as a link, never followed. Hold `update.lock`.
  @discardableResult
  func prune(keeping version: String?) throws -> [URL] {
    let doomed = slots().filter { $0.version != version }.map(\.dir) + strayLinks()
    for dir in doomed { try FileManager.default.removeItem(at: dir) }
    return doomed
  }

  /// Removes downloads that are not newer than the official app (the official app caught up). Hold `update.lock`.
  @discardableResult
  func pruneSuperseded() throws -> [URL] {
    guard let official = official() else { return [] }
    let doomed = slots().filter { !VersionCompare.isNewer($0.version, than: official.version) }.map(\.dir)
    for dir in doomed { try FileManager.default.removeItem(at: dir) }
    return doomed
  }

  /// `<version>.noindex` real directories directly in `root` with a valid version.
  private func slots() -> [(version: String, dir: URL)] {
    entries().compactMap { name in
      guard name.hasSuffix(Self.slotSuffix) else { return nil }
      let version = String(name.dropLast(Self.slotSuffix.count))
      let dir = root.appendingPathComponent(name, isDirectory: true)
      guard Self.isValidVersion(version), Self.isRealDirectory(dir) else { return nil }
      return (version, dir)
    }
  }

  /// Symlinks named like a slot: never followed, removed with the other slots.
  private func strayLinks() -> [URL] {
    entries().filter { $0.hasSuffix(Self.slotSuffix) }.map { root.appendingPathComponent($0) }.filter(Self.isSymlink)
  }

  private func entries() -> [String] {
    guard Self.isRealDirectory(root) else { return [] }
    return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
  }

  static func bundleId(of app: URL) -> String? {
    let url = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: url), let info = try? PlistPatcher.decode(data) else { return nil }
    return info["CFBundleIdentifier"] as? String
  }

  static func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }

  static func isSymlink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }
}
