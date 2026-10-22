import Foundation
import Support

public enum AgentKind: String, Sendable, CaseIterable {
  /// Retired: launch at login is the menu switch «Открывать при старте системы» (`SMAppService`). The kind stays
  /// only so the CLI can explain that and the app can find (and trash) an old plist at `installURL(kind: .app)`.
  case app
  case updateWatcher

  /// The CLI spelling: `app` | `update-watcher`.
  public init?(argument: String) {
    switch argument {
    case "app": self = .app
    case "update-watcher": self = .updateWatcher
    default: return nil
    }
  }

  /// No plist is generated for a retired kind any more.
  public var isRetired: Bool { self == .app }

  public var label: String {
    switch self {
    case .app: BuildInfo.bundleId
    case .updateWatcher: "\(BuildInfo.bundleId).update-watcher"
    }
  }
}

/// The LaunchAgent property list for the update watcher (`cmacc update check`), and where agents live.
/// Generated only; installing is the user's step (`launchctl bootstrap`), never done automatically.
public enum AgentPlist {
  public static let officialInfoPlist = "/Applications/Claude.app/Contents/Info.plist"

  /// XML plist for `kind`; `nil` for a retired kind (`app`).
  public static func make(kind: AgentKind, appPath: URL, logsDir: URL) -> Data? {
    guard let dict = dictionary(kind: kind, appPath: appPath, logsDir: logsDir) else { return nil }
    // Only strings, arrays, booleans and integers: serialization cannot fail.
    return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
  }

  public static func installURL(kind: AgentKind, home: URL) -> URL {
    home.appendingPathComponent("Library/LaunchAgents/\(kind.label).plist")
  }

  static func dictionary(kind: AgentKind, appPath: URL, logsDir: URL) -> [String: Any]? {
    switch kind {
    case .app:
      return nil
    case .updateWatcher:
      let log = logsDir.appendingPathComponent("agent-update.log").path
      return [
        "Label": kind.label,
        "ProgramArguments": [appPath.appendingPathComponent("Contents/Helpers/cmacc").path, "update", "check", "--apply-when-idle"],
        "WatchPaths": [officialInfoPlist], "StartInterval": 3600, "RunAtLoad": true,
        "StandardOutPath": log, "StandardErrorPath": log,
      ]
    }
  }
}
