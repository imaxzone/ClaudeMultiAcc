import AppKit
import SwiftUI
import Testing
@testable import UI

/// The never-shown main menu of the accessory app: it only carries the key equivalents of the app's windows.
@MainActor
@Suite(.russian) struct AppMenuMainMenuTests {
  struct Row: Equatable, CustomStringConvertible {
    let title: String
    let action: String?
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(_ title: String, _ action: String?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
      self.title = title
      self.action = action
      self.key = key
      self.modifiers = modifiers
    }

    init(_ item: NSMenuItem) {
      title = item.title
      action = item.action.map(NSStringFromSelector)
      key = item.keyEquivalent
      modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
    }

    var description: String { "\(title) \(action ?? "-") \(modifiers.rawValue):\(key)" }
  }

  static func rows(_ item: NSMenuItem?) -> [Row] {
    item?.submenu?.items.filter { !$0.isSeparatorItem }.map(Row.init) ?? []
  }

  @Test func hasTheAppEditAndWindowMenus() throws {
    let menu = AppMainMenu.make()
    #expect(menu.items.count == 3)
    #expect(menu.items.map(\.title).dropFirst() == ["Правка", "Окно"])
    #expect(menu.items.allSatisfy { $0.submenu != nil })
    #expect(menu.items[1].submenu?.title == "Правка")
    #expect(menu.items[2].submenu?.title == "Окно")
  }

  @Test func appMenuQuitsWithCommandQ() {
    let rows = Self.rows(AppMainMenu.make().items.first)
    #expect(rows == [Row("Выйти ClaudeMultiAcc", "terminate:", "q")])
  }

  /// Standard selectors with no target, so the first responder (a text field's field editor) handles them.
  @Test func editMenuUsesTheResponderChain() throws {
    let edit = try #require(AppMainMenu.make().items.dropFirst().first)
    #expect(Self.rows(edit) == [
      Row("Отменить", "undo:", "z"),
      Row("Повторить", "redo:", "z", [.command, .shift]),
      Row("Вырезать", "cut:", "x"),
      Row("Скопировать", "copy:", "c"),
      Row("Вставить", "paste:", "v"),
      Row("Выбрать все", "selectAll:", "a"),
    ])
    #expect(edit.submenu?.items.allSatisfy { $0.target == nil } == true)
    #expect(edit.submenu?.items.contains(where: \.isSeparatorItem) == true, "undo/redo apart from the clipboard")
  }

  @Test func windowMenuClosesTheKeyWindowWithCommandW() throws {
    let window = try #require(AppMainMenu.make().items.last)
    #expect(Self.rows(window) == [Row("Закрыть", "performClose:", "w")])
    #expect(window.submenu?.items.first?.target == nil)
  }

  /// Every key equivalent is unique, so no shortcut shadows another.
  @Test func shortcutsAreUnique() {
    let rows = AppMainMenu.make().items.flatMap(Self.rows)
    let keys = rows.map { "\($0.modifiers.rawValue):\($0.key)" }
    #expect(Set(keys).count == keys.count)
  }

  @Test func installSetsTheMainMenu() {
    let app = NSApplication.shared
    let previous = app.mainMenu
    defer { app.mainMenu = previous }
    AppMainMenu.install(in: app)
    #expect(app.mainMenu?.items.last?.submenu?.items.first?.keyEquivalent == "w")
  }

  /// With a main menu, ⌘W reaches the menu panel as `performClose:` (it has no close button): it closes like Esc.
  @Test func menuPanelClosesOnPerformClose() {
    let controller = AppMenuPanelController(root: EmptyView(), model: AppMenuModel())
    var commands: [AppMenuKeyCommand] = []
    controller.onKey = { commands.append($0); return true }
    let close = NSMenuItem(title: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    #expect(controller.panel.validateUserInterfaceItem(close))
    controller.panel.performClose(nil)
    #expect(commands == [.close])
  }
}
