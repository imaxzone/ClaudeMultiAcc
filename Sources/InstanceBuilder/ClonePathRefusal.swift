import Foundation

/// Why `ClonePathPolicy` will not let a clone's app or profile be moved, swapped, trashed or quit. Nothing was changed.
/// `userMessage` is in the UI language (paths abbreviated with `~`), `description` English (logs, `code: detail`).
public enum ClonePathRefusal: Error, Equatable, Sendable {
  /// Not a clone, or the entry lacks its app path or bundle id.
  case incomplete(name: String)
  /// The registry bundle id is not `com.imaxzone.claude.<slug>` (nor the legacy `second`'s).
  case bundleId(name: String, bundleId: String)
  /// The app is not `<name>.app` directly inside `/Applications` or `~/Applications`.
  case appLocation(name: String, path: String)
  /// The official Claude or ClaudeMultiAcc itself.
  case protectedApp(name: String, path: String)
  /// A symlink or a file where the app should be.
  case notABundle(name: String, path: String)
  /// The bundle's Info.plist names another app (bundle id or `ClaudeMultiAccSlug`), or there is none.
  case foreignBundle(name: String, path: String)
  /// The profile is not exactly `~/Library/Application Support/ClaudeProfiles/<slug>`.
  case profileLocation(name: String, path: String)
  /// A symlink or a file where the profile folder should be.
  case profileNotAFolder(name: String, path: String)
  /// Another instance's app, profile or CLI folder is, holds or lies inside this path; `other` is its slug.
  case shared(name: String, path: String, other: String)
  /// The item was replaced (another device or inode, or something new) between the check and the move.
  case changed(name: String, path: String)

  /// A stable kebab-case name of the reason (logs and tests).
  public var code: String {
    switch self {
    case .incomplete: "incomplete"
    case .bundleId: "bundle-id"
    case .appLocation: "app-location"
    case .protectedApp: "protected-app"
    case .notABundle: "not-a-bundle"
    case .foreignBundle: "foreign-bundle"
    case .profileLocation: "profile-location"
    case .profileNotAFolder: "profile-not-a-folder"
    case .shared: "shared"
    case .changed: "changed"
    }
  }

  public var userMessage: String {
    switch self {
    case .incomplete(let name): BuilderText.format("path.incomplete", name)
    case .bundleId(let name, _): BuilderText.format("path.bundle-id", name)
    case .appLocation(let name, let path): BuilderText.format("path.app-location", name, path)
    case .protectedApp(let name, let path): BuilderText.format("path.protected-app", name, path)
    case .notABundle(let name, let path): BuilderText.format("path.not-a-bundle", name, path)
    case .foreignBundle(let name, let path): BuilderText.format("path.foreign-bundle", name, path)
    case .profileLocation(let name, let path): BuilderText.format("path.profile-location", name, path)
    case .profileNotAFolder(let name, let path): BuilderText.format("path.profile-not-a-folder", name, path)
    case .shared(let name, let path, _): BuilderText.format("path.shared", name, path)
    case .changed(let name, let path): BuilderText.format("path.changed", name, path)
    }
  }
}

extension ClonePathRefusal: CustomStringConvertible {
  public var description: String {
    switch self {
    case .incomplete(let name): "\(code): '\(name)' is not a clone with an app path and bundle id"
    case .bundleId(let name, let id): "\(code): '\(name)' has bundle id \(id), not com.imaxzone.claude.<slug>"
    case .appLocation(let name, let path): "\(code): '\(name)': \(path) is not <name>.app directly in an Applications folder"
    case .protectedApp(let name, let path): "\(code): '\(name)': \(path) is the official Claude or ClaudeMultiAcc"
    case .notABundle(let name, let path): "\(code): '\(name)': \(path) is a symlink or a file"
    case .foreignBundle(let name, let path): "\(code): '\(name)': Info.plist of \(path) names another app"
    case .profileLocation(let name, let path): "\(code): '\(name)': \(path) is not its ClaudeProfiles/<slug> folder"
    case .profileNotAFolder(let name, let path): "\(code): '\(name)': \(path) is a symlink or a file"
    case .shared(let name, let path, let other): "\(code): '\(name)': \(path) overlaps a path of \(other)"
    case .changed(let name, let path): "\(code): '\(name)': \(path) changed since the check"
    }
  }
}
