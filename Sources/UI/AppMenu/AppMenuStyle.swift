import AppKit
import SwiftUI

/// Every measurement, font, colour and motion of the new menu (approved variant «B»). Semantic system colours;
/// the update blue is `systemBlue` everywhere (banner button, tile arrow, status-item dot), whatever the accent.
enum AppMenuStyle {
  // MARK: Panel

  static let width: CGFloat = 300
  static let padding: CGFloat = 6
  static let cornerRadius: CGFloat = 12
  static let closeFade: TimeInterval = 0.12

  // MARK: Cards (update banner, release row)

  static let cardMargin: CGFloat = 4
  static let cardCorner: CGFloat = 10
  static let bannerPadding = EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
  static let releasePadding = EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 8)
  /// Between the banner's text and its button, at least.
  static let bannerGap: CGFloat = 12
  static let bannerButtonInset: CGFloat = 11
  /// How far the banner title may shrink before it truncates (only with a very long version).
  static let bannerTitleScale: CGFloat = 0.85

  // MARK: Grid

  static let columns = AppMenuLayout.columns
  static let gridInsets = EdgeInsets(top: 4, leading: 4, bottom: 2, trailing: 4)
  static let gridSpacing: CGFloat = 2
  static var tileWidth: CGFloat {
    let inner = width - 2 * padding - gridInsets.leading - gridInsets.trailing
    return ((inner - CGFloat(columns - 1) * gridSpacing) / CGFloat(columns)).rounded(.down)
  }
  static let tilePadding = EdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
  static let tileCorner: CGFloat = 10
  static let tileSpacing: CGFloat = 4
  /// The icon frame; the artwork fills 824 of 1024 px on the macOS icon grid (≈ 48 pt here).
  static let icon: CGFloat = 60
  static var artworkInset: CGFloat { icon * 100 / 1024 }
  static var artwork: CGFloat { icon - 2 * artworkInset }
  static let badge: CGFloat = 18
  /// The gap cut out of the icon around the badge, so the badge reads on any artwork and any background.
  static let badgeRing: CGFloat = 2
  /// The badge sits on the artwork's top-right corner (2.5 pt in, 4 pt down, as in the mockup).
  static var badgeCenter: CGPoint { CGPoint(x: icon - artworkInset - 2.5, y: artworkInset + 4) }
  static let addCorner: CGFloat = 11
  /// A clone being removed: its icon at this opacity, under a spinner on a small round platter (the spinner would
  /// get lost in the artwork, and Claude's own mark is a starburst much like it).
  static let busyOpacity: Double = 0.4
  static let busyPlatter: CGFloat = 26

  // MARK: Rows

  static let rowPadding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
  static let rowCorner: CGFloat = 6
  /// The system mini switch: a 36 × 16 pt track with a 21 × 12 pt knob.
  static let switchSize = CGSize(width: 36, height: 16)
  static let switchKnob = CGSize(width: 21, height: 12)
  static let separatorInsets = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)

  // MARK: Fonts

  enum Fonts {
    static let bannerTitle = Font.system(size: 13, weight: .semibold)
    static let detail = Font.system(size: 11)
    static let button = Font.system(size: 12, weight: .medium)
    static let tileName = Font.system(size: 11)
    static let row = Font.system(size: 13)
    static let release = Font.system(size: 12)
  }

  // MARK: Colours

  static let updateBlue = Color(nsColor: .systemBlue)
  static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)
  static let separator = Color(nsColor: .separatorColor)
  static let destructive = Color(nsColor: .systemRed)
  static let tileHover = Color.primary.opacity(0.06)
  static let tileSelected = Color.primary.opacity(0.09)
  static let tilePressed = Color.primary.opacity(0.13)
  static let addStroke = Color(nsColor: .tertiaryLabelColor)
  static let switchOn = Color(nsColor: .controlAccentColor)
  static let switchOff = Color.primary.opacity(0.1)
  static let switchKnobFill = Color(nsColor: dynamic(light: .white, dark: NSColor(white: 0.87, alpha: 1)))
  static let pill = Color.primary.opacity(0.08)
  static let pillHighlighted = Color.primary.opacity(0.14)
  /// A lifted white card on the light menu, a faint light one on the dark menu.
  static let bannerFill = Color(nsColor: dynamic(light: .white.withAlphaComponent(0.9), dark: .white.withAlphaComponent(0.08)))
  static let releaseFill = Color.primary.opacity(0.045)
  static let cardEdge = Color.primary.opacity(0.08)
  static let busyPlatterFill = Color(nsColor: dynamic(
    light: .white.withAlphaComponent(0.94), dark: NSColor(white: 0.17, alpha: 0.94)))
  /// The panel's hairline, as on system menus.
  static let panelEdge = dynamic(light: .black.withAlphaComponent(0.16), dark: .white.withAlphaComponent(0.16))

  // MARK: Motion

  static let highlight = Animation.easeOut(duration: 0.12)
  static let pressedScale: CGFloat = 0.96

  /// No motion when the user asked the system to reduce it.
  @MainActor static var liveHighlight: Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : highlight
  }

  /// The menu's height at its fixed width. `fittingSize` / `intrinsicContentSize` would size multi-line texts for
  /// their line limit before the width is known; an explicit proposal gives the laid-out height.
  @MainActor
  static func height<V: View>(_ controller: NSHostingController<V>) -> CGFloat {
    controller.sizeThatFits(in: CGSize(width: width, height: 10_000)).height.rounded(.up)
  }

  static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
  }
}
