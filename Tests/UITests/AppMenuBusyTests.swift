import AppKit
import Support
import SwiftUI
import Testing
@testable import UI

/// While an update runs or a clone is being removed, the menu says so and refuses a second click; `reload()` also
/// picks up a ClaudeMultiAcc release found between opens.
@MainActor
@Suite(.russian) struct AppMenuBusyTests {
  static let updating = AppMenuBusy(updating: true)
  static let deletingMv2 = AppMenuBusy(deleting: ["mv2"])

  // MARK: The value

  @Test func idleMeansNothingBusy() {
    #expect(AppMenuBusy.idle == AppMenuBusy(updating: false, deleting: []))
    #expect(AppMenuBusy.idle.isIdle)
    #expect(!Self.updating.isIdle && !Self.deletingMv2.isIdle)
    #expect(Self.deletingMv2.isDeleting("mv2") && !Self.deletingMv2.isDeleting("second"))
  }

  // MARK: Reading it

  @Test func controllerWithoutABusySourceIsIdle() {
    let controller = AppMenuController(
      instances: { AppMenuContentTests.instances }, login: FakeLaunchAtLogin(), actions: RecordingMenuActions())
    controller.reload()
    #expect(controller.model.busy == .idle)
  }

  @Test func reloadAndOpenReadTheBusyState() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    #expect(controller.model.busy == .idle)
    fixture.busy.state = Self.updating
    controller.reload()
    #expect(controller.model.busy == Self.updating)
    fixture.busy.state = Self.deletingMv2
    controller.prepareToOpen()
    #expect(controller.model.busy == Self.deletingMv2)
  }

  @Test func busyChangedRereadsOnlyTheBusyState() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.reload()
    let requests = fixture.icons.requests.count
    fixture.busy.state = Self.updating
    controller.busyChanged()
    #expect(controller.model.busy == Self.updating)
    #expect(fixture.icons.requests.count == requests, "no file reads")
    fixture.busy.state = .idle
    controller.busyChanged()
    #expect(controller.model.busy == .idle)
  }

  // MARK: Updating

  @Test func bannerButtonDoesNothingWhileUpdating() {
    let fixture = AppMenuFixture()
    fixture.busy.state = Self.updating
    let controller = fixture.controller()
    controller.prepareToOpen()
    controller.activate(.updateAll)
    #expect(fixture.actions.calls.isEmpty)
    fixture.busy.state = .idle
    controller.busyChanged()
    controller.activate(.updateAll)
    #expect(fixture.actions.calls == ["updateAll"])
  }

  /// The tile keeps its arrow; its «Обновить до …» and «Переустановить…» (both build the clone) are disabled, the
  /// other actions still work.
  @Test func updateAndReinstallAreDisabledWhileUpdating() throws {
    let fixture = AppMenuFixture()
    fixture.busy.state = Self.updating
    let controller = fixture.controller()
    controller.prepareToOpen()
    let tile = try #require(controller.model.content.tiles.first { $0.slug == "mv2" })
    #expect(tile.updateTo == "3.1700.0")
    let items = AppTileMenu.sections(for: tile, busy: Self.updating).joined()
    #expect(Array(items.map(\.title).prefix(2)) == ["Открыть", "Обновить до 3.1700.0"])
    #expect(items.filter { !$0.isEnabled }.map(\.command) == [.update, .reinstall])

    controller.activate(.tile("mv2"))
    let rows = try #require(fixture.presenter.menu?.items).filter { !$0.isSeparatorItem }
    #expect(rows.filter { !$0.isEnabled }.map(\.title) == ["Обновить до 3.1700.0", "Переустановить…"])
    #expect(rows.filter(\.isEnabled).count == 4)
    fixture.presenter.finish()

    controller.perform(.update, slug: "mv2")
    controller.perform(.reinstall, slug: "mv2")
    #expect(fixture.actions.calls.isEmpty, "VoiceOver cannot run the disabled ones either")
    controller.perform(.edit, slug: "mv2")
    controller.perform(.open, slug: "mv2")
    #expect(fixture.actions.calls == ["edit:mv2", "open:mv2"])
  }

  /// A disabled button is not in the keyboard order.
  @Test func keyboardSkipsTheBannerWhileUpdating() {
    let content = AppMenuContentTests.build()
    let layout = AppMenuLayout(content: content, hasRelease: false, busy: Self.updating)
    #expect(layout.linear.first == .tile("main"))
    #expect(!layout.linear.contains(.updateAll))
    #expect(AppMenuNavigation.target(from: nil, .down, in: layout) == .tile("main"))
    #expect(AppMenuNavigation.target(from: .tile("main"), .up, in: layout) == .quit)
    #expect(AppMenuLayout(content: content, hasRelease: false).linear.first == .updateAll)
  }

  // MARK: Deleting

  @Test func tileBeingDeletedOpensNoActionsAndRunsNone() {
    let fixture = AppMenuFixture()
    fixture.busy.state = Self.deletingMv2
    let controller = fixture.controller()
    controller.prepareToOpen()
    controller.activate(.tile("mv2"))
    #expect(fixture.presenter.menu == nil)
    #expect(controller.model.menuTile == nil)
    for command in AppTileCommand.allCases { controller.perform(command, slug: "mv2") }
    controller.model.highlight = AppMenuHighlight(item: .tile("mv2"), byKeyboard: true)
    controller.handle(.activate)
    controller.handle(.openApp)
    #expect(fixture.presenter.menu == nil)
    #expect(fixture.actions.calls.isEmpty)
    controller.activate(.tile("second"))
    #expect(fixture.presenter.slug == "second", "other tiles still open their actions")
  }

  @Test func everyActionOfATileBeingDeletedIsDisabled() throws {
    let tile = AppMenuPartsTests.tile("mv2")
    let items = AppTileMenu.sections(for: tile, busy: Self.deletingMv2).joined()
    #expect(!items.isEmpty && items.allSatisfy { !$0.isEnabled })
    let menu = AppTileMenu.make(for: tile, target: AppTileMenuTarget { _ in }, busy: Self.deletingMv2)
    #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
    let other = AppTileMenu.sections(for: AppMenuPartsTests.tile("second"), busy: Self.deletingMv2).joined()
    #expect(other.allSatisfy { $0.isEnabled })
    #expect(AppTileMenu.sections(for: tile).joined().allSatisfy { $0.isEnabled }, "idle by default")
  }

  @Test func busyStringsAreRussian() {
    #expect(AppMenuStrings.updating == "Обновляется…")
    #expect(AppMenuStrings.tileDeleting(name: "Claude mv2") == "Claude mv2, удаляется")
  }

  // MARK: Views

  /// The banner fits the menu whatever it says: the running update, a dozen clones, a long version.
  @Test func bannerNeverOverflowsTheMenu() {
    let inner = AppMenuStyle.width - 2 * AppMenuStyle.padding
    let dozen = (1...12).map(String.init)
    let banners = [
      AppMenuBanner(version: "3.1700.0", slugs: ["second", "mv2"], shortNames: ["2nd", "mv2"]),
      AppMenuBanner(version: "3.1700.0", slugs: dozen, shortNames: dozen),
      AppMenuBanner(version: "13.17000.100", slugs: ["mv2"], shortNames: ["mv2"]),
    ]
    for banner in banners {
      for updating in [false, true] {
        let view = UpdateBannerView(
          banner: banner, isUpdating: updating, isHighlighted: false, hasFocusRing: false, onUpdate: {},
          onHover: { _ in })
        let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: inner, height: 1000))
        #expect(size.width <= inner, "\(banner.version) \(banner.buttonTitle), updating \(updating): \(size.width)")
      }
    }
  }

  // MARK: Release

  /// A release found while the menu is closed (or open) shows without waiting for the next open.
  @Test func reloadRereadsTheRelease() {
    let source = MenuSource()
    let controller = AppMenuController(
      instances: { source.instances }, login: FakeLaunchAtLogin(), actions: RecordingMenuActions(),
      releaseInfo: { source.release }, versions: AppMenuFixture.versions, icons: FakeIcons(),
      presenter: FakeTileMenuPresenter())
    controller.reload()
    #expect(controller.model.release == nil)
    source.release = AppReleaseInfo(version: "1.4.0", pageURL: AppMenuFixture.releaseURL)
    controller.reload()
    #expect(controller.model.release?.version == "1.4.0")
    #expect(controller.model.layout.linear.last == .release)
    source.release = nil
    controller.reload()
    #expect(controller.model.release == nil)
  }
}

/// The busy state the test sets; the controller reads it on `reload()` and `busyChanged()`.
@MainActor
final class FakeBusy {
  var state = AppMenuBusy.idle
}
