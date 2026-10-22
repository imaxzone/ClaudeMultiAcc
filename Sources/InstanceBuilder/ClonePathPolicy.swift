import Foundation
import Support

/// `lstat` identity of what a path holds: device, inode and file type. A rename on the same volume keeps it; another
/// item, a new folder or a symlink put in its place does not.
public struct FileIdentity: Sendable, Hashable {
  let device: Int64
  let inode: UInt64
  let type: mode_t

  /// What is at `url` now, without following a final symlink; nil when nothing is there.
  public static func of(_ url: URL) -> FileIdentity? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), type: info.st_mode & S_IFMT)
  }

  var isDirectory: Bool { type == S_IFDIR }
}

/// A path as `ClonePathPolicy` found it; `identity` is nil when nothing was there.
public struct CheckedPath: Sendable, Equatable {
  public enum State: Sendable, Equatable {
    /// The item checked is still there.
    case unchanged
    /// Nothing is there any more.
    case gone
    /// Something else is there now, or something appeared where nothing was.
    case changed
  }

  public let url: URL
  public let identity: FileIdentity?

  init(url: URL, identity: FileIdentity?) {
    self.url = url
    self.identity = identity
  }

  /// Takes `url`'s identity now (backups and staging builds, which are found rather than named by the registry).
  static func now(_ url: URL) -> CheckedPath { CheckedPath(url: url, identity: FileIdentity.of(url)) }

  /// Compares what `url` holds now with what was checked; call it right before the item is moved.
  public func state() -> State {
    guard let current = FileIdentity.of(url) else { return .gone }
    return current == identity ? .unchanged : .changed
  }
}

/// Positive checks of the paths an `instances.json` entry names, made before its app is swapped, renamed or trashed,
/// its profile trashed, or its bundle id asked to quit (a crafted or corrupted entry must never reach Xcode,
/// `~/Documents` or the official Claude):
/// - bundle id: `com.imaxzone.claude.<slug>`, or `com.anthropic.claudefordesktop2` on slug `second` (the legacy clone);
/// - app: `<name>.app` directly inside `/Applications` or `~/Applications`, neither the official Claude nor
///   ClaudeMultiAcc, no other instance's path; when something is there, a real folder (not a symlink) whose
///   `Contents/Info.plist` has this bundle id and `ClaudeMultiAccSlug` = slug (a legacy-script `second`, built before
///   the key existed, may lack it);
/// - profile: exactly `~/Library/Application Support/ClaudeProfiles/<slug>`, a real folder (not a symlink) or nothing.
/// Paths are standardized, symlinks resolved, and compared ignoring letter case and Unicode normalization (APFS); a
/// folder also has to be the same device and inode. The checked items keep their identity (`CheckedPath`), so the
/// caller can see a swap between the check and the move.
public struct ClonePathPolicy: Sendable {
  public static let cloneBundleIdPrefix = "com.imaxzone.claude."
  static let legacySecondSlug = "second"
  static let legacyScript = "legacy-script"
  static let ownAppName = "claudemultiacc.app"
  /// Where the official Claude is installed.
  public static let vendorApp = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)

  let home: URL
  let applicationsRoots: [URL]
  let protectedApps: [URL]

  /// `systemApplications` is `/Applications` except in tests.
  public init(
    home: URL, officialApp: URL = ClonePathPolicy.vendorApp,
    systemApplications: URL = ApplicationsMover.systemApplications
  ) {
    self.home = home
    applicationsRoots = [systemApplications, home.appendingPathComponent("Applications", isDirectory: true)]
    let systemClaude = systemApplications.appendingPathComponent("Claude.app", isDirectory: true)
    protectedApps = [officialApp, systemClaude, Self.vendorApp]
  }

  // MARK: Bundle ids

  /// `com.imaxzone.claude.<slug>`, or the legacy `com.anthropic.claudefordesktop2` on slug `second` (letter case
  /// ignored, as LaunchServices does).
  public static func isCloneBundleId(_ bundleId: String, slug: Slug) -> Bool {
    let id = bundleId.lowercased()
    if id == CloneSpec.legacySecondBundleId { return slug.raw == legacySecondSlug }
    return id == cloneBundleIdPrefix + slug.raw
  }

  /// The id of some clone, slug unknown: `com.imaxzone.claude.<valid slug>` or the legacy `second`'s.
  public static func isCloneBundleId(_ bundleId: String) -> Bool {
    let id = bundleId.lowercased()
    if id == CloneSpec.legacySecondBundleId { return true }
    guard id.hasPrefix(cloneBundleIdPrefix) else { return false }
    return (try? Slug(String(id.dropFirst(cloneBundleIdPrefix.count)))) != nil
  }

  // MARK: App and profile

  /// The clone's app as checked (`identity` nil when it is not on disk). `others` are the rest of the registry.
  public func checkApp(_ instance: Instance, others: [Instance] = []) throws -> CheckedPath {
    let name = instance.name
    guard instance.kind == .clone, let bundleId = instance.bundleId, let appPath = instance.appPath else {
      throw ClonePathRefusal.incomplete(name: name)
    }
    guard Self.isCloneBundleId(bundleId, slug: instance.slug) else {
      throw ClonePathRefusal.bundleId(name: name, bundleId: bundleId)
    }
    let app = URL(fileURLWithPath: appPath, isDirectory: true).standardizedFileURL
    let shown = Self.tilde(app, home: home)
    let file = app.lastPathComponent
    guard file.lowercased().hasSuffix(".app"), file.count > ".app".count, !file.hasPrefix("."),
          applicationsRoots.contains(where: { Self.sameFolder(app.deletingLastPathComponent(), $0) })
    else { throw ClonePathRefusal.appLocation(name: name, path: shown) }
    let key = Self.key(app)
    if Self.fold(file) == Self.ownAppName || protectedApps.contains(where: { Self.key($0) == key }) {
      throw ClonePathRefusal.protectedApp(name: name, path: shown)
    }
    try checkNotShared(key, instance, others: others, shown: shown)
    guard let identity = FileIdentity.of(app) else { return CheckedPath(url: app, identity: nil) }
    guard identity.isDirectory else { throw ClonePathRefusal.notABundle(name: name, path: shown) }
    guard Self.declares(app, slug: instance.slug, bundleId: bundleId, builtBy: instance.builtBy) else {
      throw ClonePathRefusal.foreignBundle(name: name, path: shown)
    }
    return CheckedPath(url: app, identity: identity)
  }

  /// The clone's profile as checked (`identity` nil when it is not on disk), nil when the entry names none.
  public func checkProfile(_ instance: Instance, others: [Instance] = []) throws -> CheckedPath? {
    guard let profileDir = instance.profileDir else { return nil }
    let profile = URL(fileURLWithPath: profileDir, isDirectory: true).standardizedFileURL
    let shown = Self.tilde(profile, home: home)
    guard Self.fold(profile.lastPathComponent) == instance.slug.raw,
          Self.sameFolder(profile.deletingLastPathComponent(), CloneSpec.profilesRoot(home: home))
    else { throw ClonePathRefusal.profileLocation(name: instance.name, path: shown) }
    try checkNotShared(Self.key(profile), instance, others: others, shown: shown)
    guard let identity = FileIdentity.of(profile) else { return CheckedPath(url: profile, identity: nil) }
    guard identity.isDirectory else { throw ClonePathRefusal.profileNotAFolder(name: instance.name, path: shown) }
    return CheckedPath(url: profile, identity: identity)
  }

  /// No other instance's app, profile or CLI folder is, holds or lies inside `key` (empty paths name nothing).
  private func checkNotShared(_ key: String, _ instance: Instance, others: [Instance], shown: String) throws {
    for other in others where other.slug != instance.slug {
      for used in [other.appPath, other.profileDir, other.cliConfigDir].compactMap({ $0 }) where !used.isEmpty {
        let owned = Self.key(URL(fileURLWithPath: used))
        if Self.isInside(key, owned) || Self.isInside(owned, key) {
          throw ClonePathRefusal.shared(name: instance.name, path: shown, other: other.slug.raw)
        }
      }
    }
  }

  /// `Contents/Info.plist` names this clone: the registry bundle id and `ClaudeMultiAccSlug` = slug; only a
  /// legacy-script `second` may lack the key.
  static func declares(_ app: URL, slug: Slug, bundleId: String, builtBy: String?) -> Bool {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PlistPatcher.decode(data), let declared = info["CFBundleIdentifier"] as? String,
          declared.lowercased() == bundleId.lowercased()
    else { return false }
    guard let declaredSlug = info[PlistPatcher.slugKey] else {
      return builtBy == legacyScript && slug.raw == legacySecondSlug
        && bundleId.lowercased() == CloneSpec.legacySecondBundleId
    }
    return declaredSlug as? String == slug.raw
  }

  // MARK: Paths

  /// Standardized, symlinks resolved in the deepest existing ancestor, letter case and Unicode normalization folded.
  static func key(_ url: URL) -> String { fold(StagingArea.resolvedPath(url)) }

  static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }

  /// The same folder: equal keys and, when they exist, the same device and inode (a case-sensitive volume can hold
  /// folders whose names differ only in letter case).
  static func sameFolder(_ a: URL, _ b: URL) -> Bool {
    guard key(a) == key(b) else { return false }
    let resolved = { (url: URL) in FileIdentity.of(URL(fileURLWithPath: StagingArea.resolvedPath(url))) }
    return resolved(a) == resolved(b)
  }

  /// `path` is `base` or lies below it.
  static func isInside(_ path: String, _ base: String) -> Bool {
    path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
  }

  /// `~/…` for paths in the home folder (what the UI shows).
  public static func tilde(_ url: URL, home: URL) -> String {
    let base = home.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    return path.hasPrefix(base + "/") ? "~" + path.dropFirst(base.count) : path
  }
}
