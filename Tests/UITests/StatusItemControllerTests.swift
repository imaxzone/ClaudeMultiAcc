import AppKit
import Testing
import Support
@testable import UI

@MainActor
@Suite(.russian) struct StatusItemControllerTests {
  private func controller(_ fixture: AppMenuFixture) -> StatusItemController {
    StatusItemController(menu: fixture.controller())
  }

  @Test func buttonShowsTheTemplateGlyphAndTheBlueDotWhileACloneIsBehind() throws {
    let controller = controller(AppMenuFixture())
    defer { controller.remove() }
    let button = try #require(controller.statusItem.button)
    #expect(button.image?.isTemplate == true)
    #expect(button.image?.size == CGSize(width: 18, height: 18))
    #expect(!controller.dot.isHidden)
    #expect(controller.dot.superview === button)
    #expect(button.accessibilityLabel() == "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2")
    #expect(button.toolTip == button.accessibilityLabel())
    #expect(controller.dot.mode == .dot)
  }

  @Test func noDotWhenEveryCloneIsCurrent() throws {
    var fixture = AppMenuFixture()
    fixture.instances = fixture.instances.filter { $0.slug.raw != "second" && $0.slug.raw != "mv2" }
    let controller = controller(fixture)
    defer { controller.remove() }
    #expect(controller.dot.isHidden)
    #expect(controller.statusItem.button?.accessibilityLabel() == "ClaudeMultiAcc")
  }

  /// The click opens the panel, not an NSMenu, and there is no usage gauge any more.
  @Test func clickTogglesTheAppMenuInsteadOfAnNSMenu() throws {
    let controller = controller(AppMenuFixture())
    defer { controller.remove() }
    #expect(controller.statusItem.menu == nil)
    let button = try #require(controller.statusItem.button)
    #expect(button.target === controller)
    #expect(button.action != nil)
    #expect(controller.statusItem.length == NSStatusItem.squareLength)
  }

  @Test func dotFollowsReloads() async throws {
    let source = MenuSource()
    let menu = AppMenuController(
      instances: { source.instances }, login: FakeLaunchAtLogin(), actions: RecordingMenuActions(),
      releaseInfo: { nil }, versions: AppMenuFixture.versions, icons: FakeIcons(), presenter: FakeTileMenuPresenter())
    let controller = StatusItemController(menu: menu)
    defer { controller.remove() }
    #expect(!controller.dot.isHidden)
    source.instances = source.instances.filter { $0.kind != .clone }
    menu.reload()
    for _ in 0..<50 where !controller.dot.isHidden { await Task.yield() }
    #expect(controller.dot.isHidden)
    #expect(controller.statusItem.button?.accessibilityLabel() == "ClaudeMultiAcc")
  }

  // MARK: Busy

  /// The dot while a clone is behind; a tiny spinner instead while an update runs (even once nothing is behind any
  /// more, e.g. while the restart is being confirmed). Removing a clone does not touch the glyph.
  @Test func indicatorFollowsUpdatesAndTheUpdateRun() {
    let deleting = AppMenuBusy(deleting: ["mv2"])
    #expect(StatusItemController.indicator(hasUpdates: false, busy: .idle) == .none)
    #expect(StatusItemController.indicator(hasUpdates: true, busy: .idle) == .dot)
    #expect(StatusItemController.indicator(hasUpdates: true, busy: AppMenuBusy(updating: true)) == .spinner)
    #expect(StatusItemController.indicator(hasUpdates: false, busy: AppMenuBusy(updating: true)) == .spinner)
    #expect(StatusItemController.indicator(hasUpdates: false, busy: deleting) == .none)
    #expect(StatusItemController.indicator(hasUpdates: true, busy: deleting) == .dot)
  }

  @Test func labelSaysWhatIsGoingOn() {
    let content = AppMenuContentTests.build()
    let release = AppReleaseInfo(version: "1.4.0", pageURL: AppMenuFixture.releaseURL)
    let label = { (busy: AppMenuBusy, release: AppReleaseInfo?) in
      StatusItemController.accessibilityLabel(content: content, busy: busy, release: release)
    }
    #expect(label(.idle, nil) == "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2")
    #expect(label(AppMenuBusy(updating: true), nil) == "ClaudeMultiAcc — идёт обновление")
    #expect(label(AppMenuBusy(deleting: ["mv2"]), nil)
      == "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2; удаляется «Claude mv2»")
    #expect(label(AppMenuBusy(deleting: ["second", "mv2"]), nil)
      == "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2; удаляются «Claude 2nd» и «Claude mv2»")
    #expect(label(.idle, release)
      == "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2; новая версия ClaudeMultiAcc 1.4.0")
    #expect(StatusItemController.accessibilityLabel(content: .empty, busy: .idle, release: nil) == "ClaudeMultiAcc")
    #expect(StatusItemController.accessibilityLabel(content: .empty, busy: .idle, release: release)
      == "ClaudeMultiAcc — новая версия ClaudeMultiAcc 1.4.0")
    #expect(StatusItemController.accessibilityLabel(content: .empty, busy: AppMenuBusy(deleting: ["gone"]), release: nil)
      == "ClaudeMultiAcc — удаляется «gone»", "a slug without a tile is named by its slug")
  }

  @Test func busyChangedTurnsTheDotIntoASpinnerAndBack() async throws {
    let fixture = AppMenuFixture()
    let menu = fixture.controller()
    let controller = StatusItemController(menu: menu)
    defer { controller.remove() }
    let button = try #require(controller.statusItem.button)
    #expect(controller.dot.mode == .dot && !controller.dot.isHidden)
    fixture.busy.state = AppMenuBusy(updating: true)
    menu.busyChanged()
    for _ in 0..<50 where controller.dot.mode != .spinner { await Task.yield() }
    #expect(controller.dot.mode == .spinner && !controller.dot.isHidden)
    #expect(button.image?.isTemplate == true, "the glyph stays a template")
    #expect(button.accessibilityLabel() == "ClaudeMultiAcc — идёт обновление")
    fixture.busy.state = .idle
    menu.busyChanged()
    for _ in 0..<50 where controller.dot.mode != .dot { await Task.yield() }
    #expect(controller.dot.mode == .dot)
    #expect(button.accessibilityLabel() == "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2")
  }

  @Test func releaseFoundBetweenOpensReachesTheLabel() async throws {
    let source = MenuSource()
    let menu = AppMenuController(
      instances: { source.instances }, login: FakeLaunchAtLogin(), actions: RecordingMenuActions(),
      releaseInfo: { source.release }, versions: AppMenuFixture.versions, icons: FakeIcons(),
      presenter: FakeTileMenuPresenter())
    let controller = StatusItemController(menu: menu)
    defer { controller.remove() }
    let button = try #require(controller.statusItem.button)
    source.release = AppReleaseInfo(version: "1.4.0", pageURL: AppMenuFixture.releaseURL)
    menu.reload()
    let expected = "ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2; новая версия ClaudeMultiAcc 1.4.0"
    for _ in 0..<50 where button.accessibilityLabel() != expected { await Task.yield() }
    #expect(button.accessibilityLabel() == expected)
  }
}
