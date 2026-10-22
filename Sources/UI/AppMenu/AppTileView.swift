import AppKit
import SwiftUI

/// The blue circle with a white arrow: «there is a newer Claude for this app».
struct UpdateBadge: View {
  var size: CGFloat = AppMenuStyle.badge

  var body: some View {
    Circle()
      .fill(AppMenuStyle.updateBlue)
      .overlay {
        Image(systemName: "arrow.up")
          .font(.system(size: size * 0.56, weight: .bold))
          .foregroundStyle(.white)
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// An app icon with, when the app is behind, the update badge on its top-right corner. The badge sits in a gap cut
/// out of the icon, so it reads on any artwork and on the light and dark menu alike.
struct AppIconView: View {
  let image: NSImage?
  let showsUpdate: Bool

  var body: some View {
    let size = AppMenuStyle.icon
    let center = AppMenuStyle.badgeCenter
    Image(nsImage: image ?? NSWorkspace.shared.icon(for: .applicationBundle))
      .resizable()
      .interpolation(.high)
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
      .mask {
        ZStack {
          Rectangle()
          if showsUpdate {
            Circle()
              .frame(width: AppMenuStyle.badge + 2 * AppMenuStyle.badgeRing,
                     height: AppMenuStyle.badge + 2 * AppMenuStyle.badgeRing)
              .position(center)
              .blendMode(.destinationOut)
          }
        }
        .compositingGroup()
      }
      .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
      .overlay {
        if showsUpdate { UpdateBadge().position(center) }
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// A grid cell's background: hover, keyboard focus (with the system focus ring), pressed and «menu open».
struct TileButtonStyle: ButtonStyle {
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: AppMenuStyle.tileCorner, style: .continuous)
    configuration.label
      .background(shape.fill(fill(pressed: configuration.isPressed)))
      .overlay(shape.strokeBorder(AppMenuStyle.focusRing, lineWidth: 2.5).opacity(hasFocusRing ? 1 : 0))
      .scaleEffect(configuration.isPressed ? AppMenuStyle.pressedScale : 1)
      .animation(AppMenuStyle.liveHighlight, value: configuration.isPressed)
  }

  private func fill(pressed: Bool) -> Color {
    if pressed { return AppMenuStyle.tilePressed }
    if isSelected { return AppMenuStyle.tileSelected }
    return isHighlighted ? AppMenuStyle.tileHover : .clear
  }
}

/// One app: icon (with the update badge) and its name. A click (or a right-click, which the panel routes) opens the
/// app's actions menu at the tile, «Открыть» first; VoiceOver's default action does the same and its custom actions
/// are the menu's rows. A clone being removed is dimmed under a small spinner, loses its badge and opens nothing; it
/// keeps its keyboard cell.
struct AppTileView: View {
  let tile: AppTile
  let icon: NSImage?
  var busy = AppMenuBusy.idle
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let isSelected: Bool
  let anchors: AppMenuAnchors?
  let onActivate: () -> Void
  let onHover: (Bool) -> Void
  let onCommand: (AppTileCommand) -> Void

  private var isDeleting: Bool { busy.isDeleting(tile.slug) }

  var body: some View {
    Button(action: onActivate) {
      VStack(spacing: AppMenuStyle.tileSpacing) {
        AppIconView(image: icon, showsUpdate: tile.updateTo != nil && !isDeleting)
          .opacity(isDeleting ? AppMenuStyle.busyOpacity : 1)
          .overlay {
            if isDeleting { TileBusyMark() }
          }
        Text(tile.name)
          .font(AppMenuStyle.Fonts.tileName)
          .foregroundStyle(isDeleting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .truncationMode(.middle)
          .fixedSize(horizontal: false, vertical: true)
      }
      .tileCell()
    }
    .buttonStyle(TileButtonStyle(
      isHighlighted: isHighlighted && !isDeleting, hasFocusRing: hasFocusRing, isSelected: isSelected && !isDeleting))
    .disabled(isDeleting)
    .background(TileAnchor(slug: tile.slug, anchors: anchors))
    .menuControl(onHover: onHover)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(isDeleting ? AppMenuStrings.tileDeleting(name: tile.name) : tile.accessibilityLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint(isDeleting ? "" : AppMenuStrings.tileHint)
    .accessibilityAction { onActivate() }
    .accessibilityActions {
      ForEach(AppTileMenu.sections(for: tile, busy: busy).joined().filter(\.isEnabled), id: \.command) { item in
        Button(item.title) { onCommand(item.command) }
      }
    }
  }
}

/// The system's spinner, sized for the menu; VoiceOver hears the busy state from the control's own label.
struct MenuSpinner: View {
  var size: ControlSize = .small

  var body: some View {
    ProgressView()
      .progressViewStyle(.circular)
      .controlSize(size)
      .accessibilityHidden(true)
  }
}

/// The spinner over the dimmed icon of a clone being removed, on a round platter in the menu's colour.
struct TileBusyMark: View {
  var body: some View {
    MenuSpinner(size: .small)
      .frame(width: AppMenuStyle.busyPlatter, height: AppMenuStyle.busyPlatter)
      .background(
        Circle()
          .fill(AppMenuStyle.busyPlatterFill)
          .shadow(color: .black.opacity(0.2), radius: 1.5, y: 0.5))
  }
}

/// The last cell: a dashed square «+ Добавить».
struct AddTileView: View {
  let isHighlighted: Bool
  let hasFocusRing: Bool
  let onActivate: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: onActivate) {
      VStack(spacing: AppMenuStyle.tileSpacing) {
        ZStack {
          RoundedRectangle(cornerRadius: AppMenuStyle.addCorner, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            .foregroundStyle(isHighlighted ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppMenuStyle.addStroke))
          Image(systemName: "plus")
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(.secondary)
        }
        .frame(width: AppMenuStyle.artwork, height: AppMenuStyle.artwork)
        .frame(width: AppMenuStyle.icon, height: AppMenuStyle.icon)
        Text(AppMenuStrings.add)
          .font(AppMenuStyle.Fonts.tileName)
          .foregroundStyle(.secondary)
      }
      .tileCell()
    }
    .buttonStyle(TileButtonStyle(isHighlighted: isHighlighted, hasFocusRing: hasFocusRing, isSelected: false))
    .menuControl(onHover: onHover)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(AppMenuStrings.addLabel)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { onActivate() }
  }
}

extension View {
  /// A grid cell: fixed column width, as tall as the tallest cell of its row, hit-testable everywhere.
  func tileCell() -> some View {
    padding(AppMenuStyle.tilePadding)
      .frame(width: AppMenuStyle.tileWidth)
      .frame(maxHeight: .infinity, alignment: .top)
      .contentShape(RoundedRectangle(cornerRadius: AppMenuStyle.tileCorner, style: .continuous))
  }

  /// Controls in the menu never take SwiftUI focus (the panel owns the keyboard) and highlight on hover.
  func menuControl(onHover: @escaping (Bool) -> Void) -> some View {
    focusable(false)
      .focusEffectDisabled()
      .onHover(perform: onHover)
  }
}
