import AppKit

/// The menu-bar glyph of ClaudeMultiAcc, drawn in code as a template image: a filled rounded square with a spark
/// knocked out of it, in front of the outline of a second square — several Claudes. While a clone is behind (or an
/// update runs), a round gap is cut at the top-right corner for the red dot or the spinner (`StatusDotView`), which
/// is not part of the template.
public enum StatusGlyph {
  public static let size = CGSize(width: 18, height: 18)
  /// The red update dot, in glyph coordinates (origin bottom-left): its centre and the diameter of its red fill.
  public static let dotCenter = CGPoint(x: 15, y: 15)
  public static let dotDiameter: CGFloat = 6
  /// The white ring around the red fill, like a notification badge; it sets the dot apart on any menu bar.
  public static let dotRingWidth: CGFloat = 1.25
  public static var dotOuterDiameter: CGFloat { dotDiameter + 2 * dotRingWidth }
  public static let dotFill = NSColor.systemRed
  public static let dotRing = NSColor.white
  /// The open ring that spins in the same place while an update runs: the outer diameter of its red line, the line,
  /// the white outline on each side of it (like the dot's ring) and the sweep.
  public static let spinnerDiameter: CGFloat = 7
  public static let spinnerLineWidth: CGFloat = 1.5
  public static let spinnerOutlineWidth: CGFloat = 1
  static let spinnerSweep: CGFloat = 0.75
  /// The spinner with its outline.
  public static var spinnerOuterDiameter: CGFloat { spinnerDiameter + 2 * spinnerOutlineWidth }
  /// The transparent ring around the dot (and its white ring).
  static let cutoutDiameter: CGFloat = 10

  /// The mark's geometry; the app icon (`assets/AppIcon.icon`) draws the same shapes scaled by 36 around (9.35, 9.35).
  static let front = CGRect(x: 1.5, y: 1.5, width: 12, height: 12)
  static let back = CGRect(x: 5, y: 5, width: 11.5, height: 11.5)
  static let frontRadius: CGFloat = 3.4
  static let backRadius: CGFloat = 3.2

  /// The template glyph; `cutout` leaves room for the update dot.
  public static func image(cutout: Bool) -> NSImage {
    let image = NSImage(size: size, flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      draw(in: context, cutout: cutout)
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = AppMenuStrings.appName
    return image
  }

  private static func draw(in context: CGContext, cutout: Bool) {
    context.setFillColor(NSColor.black.cgColor)
    context.setStrokeColor(NSColor.black.cgColor)
    // The second square: only its outline, peeking out top-right.
    context.setLineWidth(1.4)
    context.addPath(CGPath(roundedRect: back, cornerWidth: backRadius, cornerHeight: backRadius, transform: nil))
    context.strokePath()
    // A clear margin around the front square separates the two shapes.
    context.setBlendMode(.clear)
    let margin = front.insetBy(dx: -1.3, dy: -1.3)
    context.addPath(CGPath(roundedRect: margin, cornerWidth: frontRadius + 1.3, cornerHeight: frontRadius + 1.3,
                           transform: nil))
    context.fillPath()
    context.setBlendMode(.normal)
    context.addPath(CGPath(roundedRect: front, cornerWidth: frontRadius, cornerHeight: frontRadius, transform: nil))
    context.fillPath()
    // The spark: four long and four short rays, knocked out.
    context.setBlendMode(.clear)
    context.setLineCap(.round)
    context.setLineWidth(1.35)
    let center = CGPoint(x: front.midX, y: front.midY)
    for index in 0..<8 {
      let angle = CGFloat(index) * .pi / 4
      let length: CGFloat = index.isMultiple(of: 2) ? 3.7 : 2.7
      context.move(to: center)
      context.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
    }
    context.strokePath()
    if cutout {
      let d = cutoutDiameter
      context.fillEllipse(in: CGRect(x: dotCenter.x - d / 2, y: dotCenter.y - d / 2, width: d, height: d))
    }
    context.setBlendMode(.normal)
  }
}
