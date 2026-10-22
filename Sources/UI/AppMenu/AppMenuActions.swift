import AppKit
import Foundation

/// What the menu asks the app to do. The menu closes itself before calling any of these (except
/// `checkClaudeUpdates`), so a window or alert opened by the app never appears under it.
@MainActor
public protocol AppMenuActions: AnyObject {
  /// «Открыть» in a tile's actions, and ⌥Return on a tile: launches the app or brings it to the front.
  func open(slug: String)
  /// «Обновить N» in the banner: every clone that is behind.
  func updateAll()
  /// «Обновить до …» in a clone's actions.
  func update(slug: String)
  /// «Изменить…».
  func edit(slug: String)
  /// «Переустановить…»: the editor of that clone, which offers to rebuild it as it is.
  func reinstall(slug: String)
  func showInFinder(slug: String)
  /// «Удалить «…»…» (the app asks what to delete).
  func delete(slug: String)
  /// The «+ Добавить» tile.
  func add()
  /// «Скачать» in the «Доступна новая версия ClaudeMultiAcc …» row.
  func openReleasePage(_ url: URL)
  /// The ↻ button in the header: one manual check for a newer Claude. The menu stays open and follows the check
  /// through `AppMenuController.claudeUpdateChanged()`; the app shows an alert if it fails.
  func checkClaudeUpdates()
  func quit()
}

/// One command of a tile's actions menu.
public enum AppTileCommand: String, Sendable, CaseIterable {
  case open, update, edit, reinstall, showInFinder, delete

  /// The commands that build the clone again; disabled while an update runs.
  var builds: Bool { self == .update || self == .reinstall }
}

/// A row of a tile's actions menu, independent of AppKit (tests, VoiceOver actions and the NSMenu share it).
public struct AppTileMenuItem: Equatable, Sendable {
  public let command: AppTileCommand
  public let title: String
  public let symbol: String
  public let isDestructive: Bool
  /// Off for «Обновить до …» and «Переустановить…» while an update runs, and for every action of a clone being
  /// removed.
  public var isEnabled = true
}

/// The menu a tile opens (click, right-click, Return): «Открыть», «Обновить до …» (only when behind), «Изменить…»,
/// «Переустановить…», «Показать в Finder», separator, «Удалить «…»…» in red; the official app gets «Открыть» and
/// «Показать в Finder». While `busy`, the same rows stay but «Обновить до …» and «Переустановить…» (an update runs)
/// or all of them (the clone is being removed) are disabled.
@MainActor
public enum AppTileMenu {
  public static func sections(for tile: AppTile, busy: AppMenuBusy = .idle) -> [[AppTileMenuItem]] {
    let rows = rows(for: tile)
    guard !busy.isIdle else { return rows }
    let removing = busy.isDeleting(tile.slug)
    return rows.map { section in
      section.map { item in
        var item = item
        item.isEnabled = !removing && !(busy.updating && item.command.builds)
        return item
      }
    }
  }

  private static func rows(for tile: AppTile) -> [[AppTileMenuItem]] {
    let open = AppTileMenuItem(
      command: .open, title: AppMenuStrings.open, symbol: "arrow.up.forward.app", isDestructive: false)
    let finder = AppTileMenuItem(
      command: .showInFinder, title: AppMenuStrings.showInFinder, symbol: "folder", isDestructive: false)
    guard !tile.isOfficial else { return [[open, finder]] }
    let update = tile.updateTo.map {
      AppTileMenuItem(
        command: .update, title: AppMenuStrings.updateTo(version: $0), symbol: "arrow.up.circle", isDestructive: false)
    }
    let edit = AppTileMenuItem(command: .edit, title: AppMenuStrings.edit, symbol: "pencil", isDestructive: false)
    // Shown with «Изменить…»: the editor says when a clone cannot be rebuilt.
    let reinstall = AppTileMenuItem(
      command: .reinstall, title: AppMenuStrings.reinstall, symbol: "arrow.clockwise", isDestructive: false)
    let delete = AppTileMenuItem(
      command: .delete, title: AppMenuStrings.delete(name: tile.name), symbol: "trash", isDestructive: true)
    return [[open, update, edit, reinstall, finder].compactMap { $0 }, [delete]]
  }

  /// The commands a tile runs right now (its enabled rows).
  static func enabledCommands(for tile: AppTile, busy: AppMenuBusy) -> [AppTileCommand] {
    sections(for: tile, busy: busy).joined().filter(\.isEnabled).map(\.command)
  }

  /// The AppKit menu; `target` receives the chosen command (menu items hold their target weakly: keep it alive).
  public static func make(for tile: AppTile, target: AppTileMenuTarget, busy: AppMenuBusy = .idle) -> NSMenu {
    let menu = NSMenu(title: tile.name)
    menu.autoenablesItems = false
    for (index, section) in sections(for: tile, busy: busy).enumerated() {
      if index > 0 { menu.addItem(.separator()) }
      for entry in section { menu.addItem(item(entry, target: target)) }
    }
    return menu
  }

  private static func item(_ entry: AppTileMenuItem, target: AppTileMenuTarget) -> NSMenuItem {
    let item = NSMenuItem(title: entry.title, action: #selector(AppTileMenuTarget.chooseCommand(_:)), keyEquivalent: "")
    item.target = target
    item.representedObject = entry.command.rawValue
    item.isEnabled = entry.isEnabled
    let symbol = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
    if entry.isDestructive {
      item.attributedTitle = NSAttributedString(
        string: entry.title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
      item.image = symbol?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
    } else {
      item.image = symbol
    }
    return item
  }
}

/// Receives the command chosen in a tile's actions menu.
@MainActor
public final class AppTileMenuTarget: NSObject {
  private let handler: (AppTileCommand) -> Void

  public init(handler: @escaping (AppTileCommand) -> Void) {
    self.handler = handler
  }

  @objc public func chooseCommand(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let command = AppTileCommand(rawValue: raw) else { return }
    handler(command)
  }
}
