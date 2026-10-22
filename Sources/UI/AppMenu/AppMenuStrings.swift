import Foundation
import Support

/// Every user-facing string of the status item and its menu, in the UI language (`Resources/*.lproj`).
/// (The login switch's subtitles live with the switch, in `LaunchAtLoginText`.)
public enum AppMenuStrings {
  public static let appName = "ClaudeMultiAcc"

  // MARK: Status item (accessibility label and tooltip)

  /// «ClaudeMultiAcc», or «ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2; новая версия ClaudeMultiAcc 1.4.0».
  static func statusItem(parts: [String]) -> String {
    parts.isEmpty ? appName : "\(appName) — " + parts.joined(separator: "; ")
  }
  static func statusUpdateAvailable(version: String, names: [String]) -> String {
    UIText.format("status.update-available", version, bannerSubtitle(names: names))
  }
  static var statusUpdating: String { UIText.string("status.updating") }
  /// «удаляется «Claude mv2»», «удаляются «Claude 2nd» и «Claude mv2»».
  static func statusDeleting(names: [String]) -> String {
    UIText.format(names.count == 1 ? "status.deleting.one" : "status.deleting.many", list(names.map(quoted)))
  }
  static func statusRelease(version: String) -> String { UIText.format("status.release", version) }

  // MARK: Update banner

  static func bannerTitle(version: String) -> String { UIText.format("banner.title", version) }
  static func bannerSubtitle(names: [String]) -> String { UIText.format("banner.subtitle", list(names)) }
  static func updateButton(count: Int) -> String {
    count == 1 ? UIText.string("banner.update") : UIText.format("banner.update-count", count)
  }
  /// The banner button while the update runs (disabled, with a spinner).
  static var updating: String { UIText.string("banner.updating") }

  /// "a", "a и b", "a, b и c" ("a and b" in English).
  static func list(_ items: [String]) -> String { Localization.list(items) }

  /// «name» in Russian, “name” in English.
  static func quoted(_ name: String) -> String { UIText.format("common.quoted", name) }

  // MARK: Tiles

  static func tileLabel(name: String, updateTo: String?) -> String {
    updateTo.map { UIText.format("tile.update-label", name, $0) } ?? name
  }
  static var tileHint: String { UIText.string("tile.hint") }
  /// A clone being removed (dimmed, with a spinner).
  static func tileDeleting(name: String) -> String { UIText.format("tile.deleting", name) }
  static var add: String { UIText.string("tile.add") }
  static var addLabel: String { UIText.string("tile.add-label") }

  // MARK: Tile actions

  static var open: String { UIText.string("action.open") }
  static func updateTo(version: String) -> String { UIText.format("action.update-to", version) }
  static var edit: String { UIText.string("action.edit") }
  static var reinstall: String { UIText.string("action.reinstall") }
  static var showInFinder: String { UIText.string("action.show-in-finder") }
  static func delete(name: String) -> String { UIText.format("action.delete", name) }

  // MARK: Rows

  public static var launchAtLogin: String { UIText.string("row.launch-at-login") }
  static var switchOn: String { UIText.string("row.switch-on") }
  static var switchOff: String { UIText.string("row.switch-off") }
  static var quit: String { UIText.string("row.quit") }
  static let quitShortcut = "⌘Q"

  // MARK: ClaudeMultiAcc release

  static func release(version: String) -> String { UIText.format("release.title", version) }
  static var download: String { UIText.string("release.download") }
  static var downloadHint: String { UIText.string("release.download-hint") }

  // MARK: Main menu (never on screen: it gives the app's windows their key equivalents)

  static var mainMenuQuit: String { UIText.string("mainmenu.quit") }
  static var editMenu: String { UIText.string("mainmenu.edit") }
  static var undo: String { UIText.string("mainmenu.undo") }
  static var redo: String { UIText.string("mainmenu.redo") }
  static var cut: String { UIText.string("mainmenu.cut") }
  static var copy: String { UIText.string("mainmenu.copy") }
  static var paste: String { UIText.string("mainmenu.paste") }
  static var selectAll: String { UIText.string("mainmenu.select-all") }
  static var windowMenu: String { UIText.string("mainmenu.window") }
  static var closeWindow: String { UIText.string("mainmenu.close") }
}
