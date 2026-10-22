import AppKit
import SwiftUI

/// Lays out a real `NSMenu` (a tile's actions menu, `AppTileMenu`) as a flat view for offscreen review: custom item
/// views as they are, standard items, section headers and separators drawn in the system menu metrics, on a rounded
/// menu-coloured panel. Materials do not render offscreen, so the panel uses `windowBackgroundColor`.
@MainActor
enum MenuSnapshot {
  static let panelPadding: CGFloat = 5
  static let cornerRadius: CGFloat = 12
  static let standardRowHeight: CGFloat = 22
  static let headerRowHeight: CGFloat = 22
  static let separatorHeight: CGFloat = 11
  /// The leading and trailing inset of a row's content, as in a system menu.
  static let horizontalInset: CGFloat = 14

  static func view(for menu: NSMenu, width: CGFloat) -> NSView {
    let rows = menu.items.filter { !$0.isHidden }.map { row(for: $0, width: width) }
    let height = rows.reduce(panelPadding * 2) { $0 + $1.frame.height }
    let panel = MenuPanelView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    var y = panelPadding
    for row in rows {
      row.frame.origin = NSPoint(x: 0, y: y)
      panel.addSubview(row)
      y += row.frame.height
    }
    return panel
  }

  private static func row(for item: NSMenuItem, width: CGFloat) -> NSView {
    if let view = item.view {
      // A plain holder keeps the hosted row where it belongs; hosting views re-place themselves in a stack.
      let holder = NSView(frame: NSRect(x: 0, y: 0, width: width, height: view.frame.height))
      view.frame = holder.bounds
      view.autoresizingMask = [.width, .height]
      holder.addSubview(view)
      return holder
    }
    let content = AnyView(MenuItemRow(item: MenuItemModel(item)))
    let height = item.isSeparatorItem ? separatorHeight : (item.isSectionHeader ? headerRowHeight : standardRowHeight)
    let host = NSHostingView(rootView: content.frame(width: width, height: height))
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    return host
  }
}

/// The rounded menu panel; flipped so rows stack from the top.
final class MenuPanelView: NSView {
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: MenuSnapshot.cornerRadius,
                            yRadius: MenuSnapshot.cornerRadius)
    NSColor.windowBackgroundColor.setFill()
    path.fill()
    NSColor.separatorColor.setStroke()
    path.lineWidth = 1
    path.stroke()
  }
}

/// What a standard `NSMenuItem` shows.
struct MenuItemModel {
  enum Kind { case separator, header, item }
  let kind: Kind
  let title: AttributedString
  let symbol: NSImage?
  let isEnabled: Bool
  let isOn: Bool
  let keyEquivalent: String
  let hasSubmenu: Bool

  @MainActor
  init(_ item: NSMenuItem) {
    kind = item.isSeparatorItem ? .separator : (item.isSectionHeader ? .header : .item)
    if let attributed = item.attributedTitle, let converted = try? AttributedString(attributed, including: \.appKit) {
      title = converted
    } else {
      title = AttributedString(item.title)
    }
    symbol = item.image
    isEnabled = item.isEnabled
    isOn = item.state == .on
    keyEquivalent = Self.keyText(item)
    hasSubmenu = item.hasSubmenu
  }

  /// "⌘1", "⌘," … as the menu prints them.
  @MainActor
  static func keyText(_ item: NSMenuItem) -> String {
    guard !item.keyEquivalent.isEmpty else { return "" }
    let mask = item.keyEquivalentModifierMask
    let modifiers = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { mask.contains($0.0) }.map(\.1).joined()
    return modifiers + item.keyEquivalent.uppercased()
  }
}

/// One standard row in menu metrics: 13 pt menu font, 16 pt image column, trailing key equivalent or chevron.
struct MenuItemRow: View {
  let item: MenuItemModel

  var body: some View {
    switch item.kind {
    case .separator:
      Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        .padding(.horizontal, MenuSnapshot.horizontalInset - 4)
    case .header:
      Text(item.title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MenuSnapshot.horizontalInset)
        .padding(.top, 4)
    case .item:
      standard
    }
  }

  private var standard: some View {
    HStack(spacing: 6) {
      Group {
        if item.isOn {
          Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
        } else if let symbol = item.symbol {
          Image(nsImage: symbol).renderingMode(symbol.isTemplate ? .template : .original)
        }
      }
      .frame(width: 16, alignment: .center)
      Text(item.title).font(.system(size: 13)).lineLimit(1)
      Spacer(minLength: 8)
      if item.hasSubmenu {
        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      } else if !item.keyEquivalent.isEmpty {
        Text(item.keyEquivalent).font(.system(size: 13)).foregroundStyle(.tertiary)
      }
    }
    .foregroundStyle(item.isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
    .padding(.horizontal, MenuSnapshot.horizontalInset)
    .frame(maxHeight: .infinity)
  }
}
