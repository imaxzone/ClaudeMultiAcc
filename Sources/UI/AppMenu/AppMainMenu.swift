import AppKit

/// The main menu of the accessory app. It is never on screen (an `.accessory` app has no menu bar of its own), but
/// AppKit looks up key equivalents only there: without it ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z / ⇧⌘Z do nothing in the text
/// fields of the «Изменить… / Добавить» window, and ⌘W / ⌘Q do nothing in any window. Every item but «Выйти» has no
/// target, so the first responder (a field editor, the key window) handles it through the responder chain.
@MainActor
public enum AppMainMenu {
  /// Installs the menu; call it once at launch, before `app.run()`.
  public static func install(in app: NSApplication) {
    app.mainMenu = make()
  }

  public static func make() -> NSMenu {
    let menu = NSMenu(title: AppMenuStrings.appName)
    // AppKit titles the first menu with the app's name whatever it is called.
    menu.addItem(submenu(AppMenuStrings.appName, [
      item(AppMenuStrings.mainMenuQuit, #selector(NSApplication.terminate(_:)), "q"),
    ]))
    menu.addItem(submenu(AppMenuStrings.editMenu, [
      item(AppMenuStrings.undo, Selector(("undo:")), "z"),
      item(AppMenuStrings.redo, Selector(("redo:")), "z", [.command, .shift]),
      .separator(),
      item(AppMenuStrings.cut, #selector(NSText.cut(_:)), "x"),
      item(AppMenuStrings.copy, #selector(NSText.copy(_:)), "c"),
      item(AppMenuStrings.paste, #selector(NSText.paste(_:)), "v"),
      item(AppMenuStrings.selectAll, #selector(NSText.selectAll(_:)), "a"),
    ]))
    menu.addItem(submenu(AppMenuStrings.windowMenu, [
      item(AppMenuStrings.closeWindow, #selector(NSWindow.performClose(_:)), "w"),
    ]))
    return menu
  }

  private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    holder.submenu = menu
    return holder
  }

  private static func item(
    _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }
}
