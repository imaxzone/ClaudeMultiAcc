import AppKit
import Support
import Testing
@testable import UI

/// The controller behind the panel: what it reads on open, and which action every item and key leads to.
@MainActor
@Suite(.russian) struct AppMenuControllerTests {
  @Test func reloadBuildsTheGridFromTheListAndTheInstalledVersions() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    #expect(controller.model.content == .empty)
    #expect(!controller.hasUpdates)
    controller.reload()
    #expect(controller.model.content == AppMenuContentTests.build())
    #expect(controller.hasUpdates)
    #expect(Set(controller.model.icons.keys) == ["main", "second", "fivex", "mv2"])
    #expect(fixture.icons.requests.first == .workspace(appPath: "/Applications/Claude.app"))
    #expect(fixture.icons.requests.contains(.bundleIcns(appPath: "/Applications/Claude mv2.app")))
  }

  @Test func everyOpenRereadsTheLoginItemTheReleaseAndTheList() {
    let login = FakeLaunchAtLogin(.needsApproval)
    let source = MenuSource()
    let controller = AppMenuController(
      instances: { source.instances }, login: login, actions: RecordingMenuActions(), releaseInfo: { source.release },
      versions: AppMenuFixture.versions, icons: FakeIcons(), presenter: FakeTileMenuPresenter())
    controller.prepareToOpen()
    #expect(login.refreshCount == 1)
    #expect(controller.model.login == AppMenuLoginRow(login))
    #expect(controller.model.login.subtitle == "Разрешите в Системных настройках")
    #expect(controller.model.release == nil)
    #expect(controller.model.content.tiles.count == 4)

    source.release = AppReleaseInfo(version: "1.4.0", pageURL: AppMenuFixture.releaseURL)
    source.instances.removeLast()
    login.state = .on
    controller.model.highlight = AppMenuHighlight(item: .quit, byKeyboard: true)
    controller.prepareToOpen()
    #expect(login.refreshCount == 2)
    #expect(controller.model.login.isOn)
    #expect(controller.model.release?.version == "1.4.0")
    #expect(controller.model.content.tiles.map(\.slug) == ["main", "second", "fivex"])
    #expect(controller.model.highlight == nil)
  }

  @Test func bannerButtonUpdatesEveryCloneBehind() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    controller.activate(.updateAll)
    #expect(fixture.actions.calls == ["updateAll"])
  }

  @Test func cloneTileOpensItsActionsAndTheChosenOneRuns() throws {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    controller.activate(.tile("mv2"))
    #expect(fixture.presenter.slug == "mv2")
    #expect(fixture.presenter.titles == [
      "Открыть", "Обновить до 3.1700.0", "Изменить…", "Переустановить…", "Показать в Finder", "—",
      "Удалить «Claude mv2»…",
    ])
    #expect(controller.model.menuTile == "mv2")
    #expect(fixture.actions.calls.isEmpty, "a click only shows the actions")
    fixture.presenter.choose("Изменить…")
    #expect(fixture.actions.calls == ["edit:mv2"])
    #expect(controller.model.menuTile == nil)

    for (title, call) in [
      ("Открыть", "open:mv2"), ("Обновить до 3.1700.0", "update:mv2"), ("Переустановить…", "reinstall:mv2"),
      ("Показать в Finder", "finder:mv2"), ("Удалить «Claude mv2»…", "delete:mv2"),
    ] {
      controller.activate(.tile("mv2"))
      fixture.presenter.choose(title)
      #expect(fixture.actions.calls.last == call)
    }
    withExtendedLifetime(controller) {}
  }

  @Test func currentCloneHasNoUpdateItem() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    controller.activate(.tile("fivex"))
    #expect(fixture.presenter.titles == [
      "Открыть", "Изменить…", "Переустановить…", "Показать в Finder", "—", "Удалить «Claude 5x акк»…",
    ])
  }

  @Test func officialTileOnlyOpensOrShowsInFinder() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    controller.activate(.tile("main"))
    #expect(fixture.presenter.titles == ["Открыть", "Показать в Finder"])
    fixture.presenter.choose("Открыть")
    #expect(fixture.actions.calls == ["open:main"])
    #expect(controller.model.menuTile == nil)
    controller.activate(.tile("main"))
    fixture.presenter.choose("Показать в Finder")
    #expect(fixture.actions.calls == ["open:main", "finder:main"])
  }

  /// A right-click or Control-click over a tile opens its actions, as a click does; elsewhere it is not the menu's.
  @Test func secondaryClickOverATileOpensItsActions() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
                          backing: .buffered, defer: true)
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let tile = NSView(frame: NSRect(x: 10, y: 100, width: 92, height: 90))
    window.contentView?.addSubview(tile)
    controller.anchors.register(tile, for: "mv2")
    #expect(!controller.secondaryClick(at: NSPoint(x: 200, y: 20), in: window))
    let other = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: true)
    #expect(!controller.secondaryClick(at: NSPoint(x: 50, y: 150), in: other))
    #expect(fixture.presenter.menu == nil)
    #expect(controller.secondaryClick(at: NSPoint(x: 50, y: 150), in: window))
    #expect(fixture.presenter.slug == "mv2")
    #expect(controller.model.menuTile == "mv2")
    #expect(fixture.actions.calls.isEmpty)
    withExtendedLifetime(window) {}
  }

  @Test func closingTheMenuWithoutAChoiceDeselectsTheTile() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    controller.activate(.tile("second"))
    #expect(controller.model.menuTile == "second")
    fixture.presenter.finish()
    #expect(controller.model.menuTile == nil)
    #expect(fixture.actions.calls.isEmpty)
  }

  /// VoiceOver custom actions call `perform` directly: it only runs what the tile's menu offers.
  @Test func commandsATileDoesNotOfferAreIgnored() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    controller.perform(.delete, slug: "main")
    controller.perform(.edit, slug: "main")
    controller.perform(.update, slug: "fivex")
    controller.perform(.reinstall, slug: "main")
    controller.perform(.edit, slug: "gone")
    controller.perform(.open, slug: "gone")
    #expect(fixture.actions.calls.isEmpty)
    controller.perform(.update, slug: "second")
    controller.perform(.open, slug: "main")
    controller.perform(.reinstall, slug: "fivex")
    #expect(fixture.actions.calls == ["update:second", "open:main", "reinstall:fivex"])
  }

  @Test func addReleaseLoginAndQuitRows() {
    var fixture = AppMenuFixture()
    fixture.release = AppReleaseInfo(version: "1.4.0", pageURL: AppMenuFixture.releaseURL)
    let controller = fixture.controller()
    controller.activate(.release)
    #expect(fixture.actions.calls.isEmpty, "the release is read on open")
    controller.prepareToOpen()
    controller.activate(.add)
    controller.activate(.release)
    controller.activate(.quit)
    #expect(fixture.actions.calls == ["add", "release:\(AppMenuFixture.releaseURL.absoluteString)", "quit"])
    controller.activate(.login)
    #expect(fixture.login.toggleCount == 1)
    #expect(controller.model.login.state == .on)
  }

  @Test func keyboardWalksTheMenuAndActivates() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.prepareToOpen()
    #expect(controller.handle(.down))
    #expect(controller.model.highlight == AppMenuHighlight(item: .updateAll, byKeyboard: true))
    controller.handle(.down)
    controller.handle(.right)
    #expect(controller.model.highlight?.item == .tile("second"))
    #expect(controller.model.hasKeyboardFocus(.tile("second")))
    controller.handle(.activate)
    #expect(fixture.presenter.slug == "second")
    #expect(fixture.actions.calls.isEmpty, "Return shows the actions")
    controller.handle(.quit)
    #expect(fixture.actions.calls == ["quit"])
    #expect(controller.handle(.close))
    #expect(controller.model.highlight == nil)
  }

  /// ⌥Return opens the highlighted tile's app without its menu; on anything else it does nothing.
  @Test func optionReturnOpensTheHighlightedApp() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.prepareToOpen()
    #expect(controller.handle(.openApp))
    controller.model.highlight = AppMenuHighlight(item: .add, byKeyboard: true)
    #expect(controller.handle(.openApp))
    #expect(fixture.actions.calls.isEmpty)
    controller.model.highlight = AppMenuHighlight(item: .tile("main"), byKeyboard: true)
    controller.handle(.openApp)
    #expect(fixture.actions.calls == ["open:main"])
    #expect(fixture.presenter.menu == nil)
    #expect(controller.model.highlight == nil, "the menu closed")
  }

  @Test func activateWithoutAHighlightDoesNothing() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.prepareToOpen()
    #expect(controller.handle(.activate))
    #expect(fixture.actions.calls.isEmpty)
    #expect(fixture.presenter.menu == nil)
  }

  @Test func hoverHighlightsLikeAMenuItemAndLeavesKeyboardFocusAlone() {
    let model = AppMenuModel()
    model.hover(.add, inside: true)
    #expect(model.highlight == AppMenuHighlight(item: .add, byKeyboard: false))
    model.hover(.add, inside: false)
    #expect(model.highlight == nil)
    model.highlight = AppMenuHighlight(item: .quit, byKeyboard: true)
    model.hover(.add, inside: false)
    #expect(model.highlight?.item == .quit)
    model.hover(.quit, inside: true)
    #expect(model.highlight == AppMenuHighlight(item: .quit, byKeyboard: false))
  }

  @Test func closedMenuReportsNotOpen() {
    let controller = AppMenuFixture().controller()
    #expect(!controller.isOpen)
    controller.close()
    #expect(!controller.isOpen)
  }

  // MARK: Login row

  /// The row shows what `LaunchAtLoginPresentation` (W3) says: switch position, availability, subtitle.
  @Test func loginRowUsesTheSharedPresentation() {
    for state in [LaunchAtLoginState.on, .off, .needsApproval, .legacyAgent, .unavailable] {
      let toggle = FakeLaunchAtLogin(state)
      let row = AppMenuLoginRow(toggle)
      #expect(row.state == state)
      #expect(row.isOn == state.isOn)
      #expect(row.isEnabled == state.isAvailable)
      #expect(row.subtitle == toggle.subtitle)
      #expect(!row.isError)
    }
    #expect(AppMenuLoginRow(FakeLaunchAtLogin(.legacyAgent)).isOn)
    #expect(!AppMenuLoginRow(FakeLaunchAtLogin(.unavailable)).isEnabled)
    let failed = AppMenuLoginRow(FakeLaunchAtLogin(.off, errorText: "Не удалось включить: нет доступа"))
    #expect(failed.subtitle == "Не удалось включить: нет доступа" && failed.isError)
    #expect(AppMenuStrings.launchAtLogin == "Открывать при старте системы")
  }
}

/// The list and the release the controller reads on open, changed by the test between opens.
@MainActor
final class MenuSource {
  var instances = AppMenuContentTests.instances
  var release: AppReleaseInfo?
}
