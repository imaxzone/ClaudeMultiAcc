import AppKit
import Support
import SwiftUI

/// Review shots of the new menu and its status item (`cmacc ui snapshot`), each light and dark:
/// - `statusitem-<appearance>@1x/@2x`, `statusitem-update-…`, `statusitem-updating-…` — the glyph without a mark, with
///   the dot, and with the spinner ring of a running update;
/// - `appmenu-normal` — every clone current, no release, the login switch on;
/// - `appmenu-update` — 2nd and mv2 behind (banner, arrows), a newer ClaudeMultiAcc, the switch off;
/// - `appmenu-focus` — keyboard focus on «Claude mv2», the switch waiting for approval;
/// - `appmenu-updating` — «Обновить 2» running: the disabled «Обновляется…» button with its spinner;
/// - `appmenu-deleting` — «Claude 5x акк» being removed: dimmed under a spinner;
/// - `appmenu-actions` — «Claude 2nd» (behind) selected with its actions menu open under it: «Открыть», «Обновить
///   до …», «Изменить…», «Переустановить…», «Показать в Finder», «Удалить «…»…»;
/// - `appmenu-official` — the official tile with its two actions, «Открыть» and «Показать в Finder».
/// The menu shots are Russian; `appmenu-normal-en`, `appmenu-update-en`, `appmenu-actions-en` and
/// `appmenu-official-en` repeat four of them in English, so the longer English labels are reviewed too.
@MainActor
enum AppMenuShots {
  /// The panel states shot on their own (file name prefix as raw value).
  enum PanelState: String, CaseIterable {
    case normal = "appmenu-normal"
    case update = "appmenu-update"
    case focus = "appmenu-focus"
    case updating = "appmenu-updating"
    case deleting = "appmenu-deleting"
  }

  static let tileMenus = [("appmenu-actions", "second"), ("appmenu-official", "main")]

  /// The shots repeated in English (file name prefix), after the Russian ones.
  static let englishPanels: [PanelState] = [.normal, .update]
  static let englishTileMenus = tileMenus

  static func all(scale: CGFloat) -> [SnapshotCatalog.Shot] {
    statusShots() + menuShots(scale: scale)
  }

  private static func statusShots() -> [SnapshotCatalog.Shot] {
    // Each file carries only the representation a display of that scale uses, as AppKit picks it.
    let marks: [(String, StatusItemIndicator)] = [("", .none), ("-update", .dot), ("-updating", .spinner)]
    return marks.flatMap { suffix, indicator in
      [CGFloat(1), 2].map { fixedScale in
        SnapshotCatalog.Shot(name: { "statusitem\(suffix)-\($0)@\(Int(fixedScale))x.png" }) { appearance in
          try SnapshotRenderer.png(
            StatusItemStrip(indicator: indicator), size: SnapshotCatalog.menuBarStrip, appearance: appearance,
            scale: fixedScale)
        }
      }
    }
  }

  /// The demo controller in `state`, filled as an open fills it.
  static func controller(_ state: PanelState) -> AppMenuController {
    switch state {
    case .normal:
      return AppMenuDemo.controller(
        versions: AppMenuDemo.versions.mapValues { _ in AppMenuDemo.officialVersion }, release: nil, login: .on)
    case .update:
      return AppMenuDemo.controller()
    case .focus:
      let controller = AppMenuDemo.controller(login: .needsApproval)
      controller.model.highlight = AppMenuHighlight(item: .tile("mv2"), byKeyboard: true)
      return controller
    case .updating:
      return AppMenuDemo.controller(busy: AppMenuBusy(updating: true))
    case .deleting:
      return AppMenuDemo.controller(busy: AppMenuBusy(deleting: ["fivex"]))
    }
  }

  private static func menuShots(scale: CGFloat) -> [SnapshotCatalog.Shot] {
    func panels(_ states: [PanelState], _ language: String) -> [SnapshotCatalog.Shot] {
      states.map { state in
        shot(state.rawValue, language) { try panel(controller(state).model, appearance: $0, scale: scale) }
      }
    }
    func menus(_ tiles: [(String, String)], _ language: String) -> [SnapshotCatalog.Shot] {
      tiles.map { name, slug in
        shot(name, language) { try withActionsMenu(tile: slug, appearance: $0, scale: scale) }
      }
    }
    return panels(PanelState.allCases, "ru") + menus(tileMenus, "ru")
      + panels(englishPanels, "en") + menus(englishTileMenus, "en")
  }

  /// `<name>-<appearance>.png` drawn in `language`; a shot in another language than Russian gets `-<language>`.
  private static func shot(
    _ name: String, _ language: String, render: @escaping (NSAppearance.Name) throws -> Data
  ) -> SnapshotCatalog.Shot {
    let infix = language == "ru" ? "" : "-\(language)"
    return SnapshotCatalog.Shot(name: { "\(name)\(infix)-\($0).png" }) { appearance in
      try Localization.$pinned.withValue(language) { try render(appearance) }
    }
  }

  /// The height the open panel takes, measured as `AppMenuPanelController` measures it.
  static func panelHeight(_ model: AppMenuModel) -> CGFloat {
    AppMenuStyle.height(NSHostingController(rootView: AppMenuSnapshotPanel(model: model, anchors: nil)))
  }

  static func panel(_ model: AppMenuModel, appearance: NSAppearance.Name, scale: CGFloat) throws -> Data {
    let size = CGSize(width: AppMenuStyle.width, height: panelHeight(model))
    return try SnapshotRenderer.png(AppMenuSnapshotPanel(model: model, anchors: nil), size: size, appearance: appearance,
                                    scale: scale)
  }

  /// The panel with `tile` selected and its actions menu laid out under it, centred, as `AnchoredTileMenuPresenter`
  /// pops it up.
  static func withActionsMenu(tile slug: String, appearance: NSAppearance.Name, scale: CGFloat) throws -> Data {
    let controller = AppMenuDemo.controller()
    controller.model.menuTile = slug
    guard let tile = controller.model.content.tiles.first(where: { $0.slug == slug }) else {
      throw SnapshotError.emptySize
    }
    let anchors = AppMenuAnchors()
    let height = panelHeight(controller.model)
    let host = NSHostingView(rootView: AppMenuSnapshotPanel(model: controller.model, anchors: anchors)
      .frame(width: AppMenuStyle.width, height: height))
    host.frame = CGRect(x: 0, y: 0, width: AppMenuStyle.width, height: height)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let anchor = anchors.view(for: slug) else { throw SnapshotError.emptySize }
    let tileRect = anchor.convert(anchor.bounds, to: host)
    window.contentView = nil

    let target = AppTileMenuTarget { _ in }
    let actions = AppTileMenu.make(for: tile, target: target)
    let menuWidth = width(of: actions)
    let menu = MenuSnapshot.view(for: actions, width: menuWidth)
    let tileBottom = host.isFlipped ? tileRect.maxY : height - tileRect.minY
    let centred = tileRect.midX - menuWidth / 2
    let menuX = AnchoredTileMenuPresenter.clampedX(centred, menuWidth: menuWidth, within: 0...AppMenuStyle.width)
    let menuOrigin = CGPoint(x: menuX.rounded(), y: tileBottom + AnchoredTileMenuPresenter.gap)
    let canvas = FlippedCanvas(frame: CGRect(
      x: 0, y: 0, width: max(AppMenuStyle.width, menuOrigin.x + menuWidth),
      height: max(height, menuOrigin.y + menu.frame.height)))
    host.frame.origin = .zero
    canvas.addSubview(host)
    menu.frame.origin = menuOrigin
    canvas.addSubview(menu)
    return try SnapshotRenderer.png(nsView: canvas, appearance: appearance, scale: scale)
  }

  static let minimumMenuWidth: CGFloat = 160
  /// AppKit leaves room after the longest title (for key equivalents); `MenuItemRow` only keeps its 8 pt spacer.
  static let menuTrailingRoom: CGFloat = 12

  /// As wide as the longest row laid out by `MenuSnapshot`, so no title is truncated (`NSMenu.size` is not
  /// reliable offscreen), never narrower than AppKit's own measure or `minimumMenuWidth`.
  static func width(of menu: NSMenu) -> CGFloat {
    let rows = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
      NSHostingView(rootView: MenuItemRow(item: MenuItemModel(item)).fixedSize()).fittingSize.width + menuTrailingRoom
    }
    return max(rows.max() ?? 0, menu.size.width, minimumMenuWidth).rounded(.up)
  }
}

/// Stacks review layers from the top-left.
final class FlippedCanvas: NSView {
  override var isFlipped: Bool { true }
}

/// The status item on a strip of menu bar between two system extras (Wi-Fi, battery): the glyph tinted like a
/// template image and, in the glyph's gap, the blue dot or the spinner ring (as `StatusDotView` draws them, still).
struct StatusItemStrip: View {
  let indicator: StatusItemIndicator

  var body: some View {
    // Whole-point slots (24 pt each, 16 pt apart), so every item sits on the pixel grid like a real status item.
    HStack(spacing: 16) {
      Image(systemName: "wifi").font(.system(size: 14, weight: .medium)).frame(width: 24, height: 24)
      Image(nsImage: StatusGlyph.image(cutout: indicator != .none))
        .renderingMode(.template)
        .frame(width: StatusGlyph.size.width, height: StatusGlyph.size.height)
        .overlay { mark.position(x: StatusGlyph.dotCenter.x, y: StatusGlyph.size.height - StatusGlyph.dotCenter.y) }
        .frame(width: 24, height: 24)
      Image(systemName: "battery.75percent").font(.system(size: 15, weight: .regular)).frame(width: 24, height: 24)
    }
    .foregroundStyle(.primary)
    .frame(width: SnapshotCatalog.menuBarStrip.width, height: SnapshotCatalog.menuBarStrip.height)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var mark: some View {
    switch indicator {
    case .none:
      EmptyView()
    case .dot:
      Circle()
        .fill(AppMenuStyle.updateBlue)
        .frame(width: StatusGlyph.dotDiameter, height: StatusGlyph.dotDiameter)
    case .spinner:
      // `StatusDotView.ringPath`: three quarters from the top, clockwise.
      Circle()
        .inset(by: StatusGlyph.spinnerLineWidth / 2)
        .trim(from: 0, to: StatusGlyph.spinnerSweep)
        .stroke(AppMenuStyle.updateBlue, style: StrokeStyle(lineWidth: StatusGlyph.spinnerLineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .frame(width: StatusGlyph.spinnerDiameter, height: StatusGlyph.spinnerDiameter)
    }
  }
}
