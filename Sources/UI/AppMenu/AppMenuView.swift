import AppKit
import SwiftUI

/// The whole menu, top to bottom: update banner (only while a clone is behind), the grid of apps ending in
/// «+ Добавить», a separator, the login switch, «Выйти», and under them the ClaudeMultiAcc release card (only when
/// there is one).
struct AppMenuView: View {
  @ObservedObject var model: AppMenuModel
  let anchors: AppMenuAnchors?
  let actions: AppMenuViewActions

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let banner = model.content.banner {
        UpdateBannerView(
          banner: banner, isUpdating: model.busy.updating, isHighlighted: model.isHighlighted(.updateAll),
          hasFocusRing: model.hasKeyboardFocus(.updateAll), onUpdate: { actions.activate(.updateAll) },
          onHover: hover(.updateAll))
      }
      grid
      AppMenuSeparator()
      LoginRowView(
        row: model.login, isHighlighted: model.isHighlighted(.login), hasFocusRing: model.hasKeyboardFocus(.login),
        onToggle: { actions.activate(.login) }, onHover: hover(.login))
      QuitRowView(isHighlighted: model.isHighlighted(.quit), onQuit: { actions.activate(.quit) }, onHover: hover(.quit))
      if let release = model.release {
        AppMenuSeparator()
        ReleaseRowView(
          release: release, isHighlighted: model.isHighlighted(.release),
          hasFocusRing: model.hasKeyboardFocus(.release), onOpen: { actions.activate(.release) },
          onHover: hover(.release))
      }
    }
    .padding(AppMenuStyle.padding)
    .frame(width: AppMenuStyle.width, alignment: .top)
    .animation(AppMenuStyle.liveHighlight, value: model.highlight)
    .animation(AppMenuStyle.liveHighlight, value: model.menuTile)
    .animation(AppMenuStyle.liveHighlight, value: model.busy)
  }

  private enum Cell: Identifiable {
    case tile(AppTile)
    case add
    var id: String {
      switch self {
      case .tile(let tile): "tile-\(tile.slug)"
      case .add: "add"
      }
    }
  }

  private var rows: [[Cell]] {
    let cells = model.content.tiles.map(Cell.tile) + [.add]
    return stride(from: 0, to: cells.count, by: AppMenuStyle.columns).map {
      Array(cells[$0..<min($0 + AppMenuStyle.columns, cells.count)])
    }
  }

  private var grid: some View {
    VStack(spacing: AppMenuStyle.gridSpacing) {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .top, spacing: AppMenuStyle.gridSpacing) {
          ForEach(row) { cell($0) }
          if row.count < AppMenuStyle.columns {
            Spacer(minLength: 0)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(AppMenuStyle.gridInsets)
  }

  @ViewBuilder
  private func cell(_ cell: Cell) -> some View {
    switch cell {
    case .tile(let tile):
      let item = AppMenuItem.tile(tile.slug)
      AppTileView(
        tile: tile, icon: model.icons[tile.slug], busy: model.busy, isHighlighted: model.isHighlighted(item),
        hasFocusRing: model.hasKeyboardFocus(item), isSelected: model.menuTile == tile.slug, anchors: anchors,
        onActivate: { actions.activate(item) }, onHover: hover(item),
        onCommand: { actions.perform($0, tile.slug) })
    case .add:
      AddTileView(
        isHighlighted: model.isHighlighted(.add), hasFocusRing: model.hasKeyboardFocus(.add),
        onActivate: { actions.activate(.add) }, onHover: hover(.add))
    }
  }

  private func hover(_ item: AppMenuItem) -> (Bool) -> Void {
    { [model] inside in model.hover(item, inside: inside) }
  }
}
