import AppKit
import IconRenderer

/// A stand-in app icon for review snapshots (the real vendor icon is never read): a warm squircle on the macOS icon
/// grid, optionally with the clone badge baked in by `BadgeCompositor`.
enum DemoIcon {
  static let canvas: CGFloat = 1024

  static func image(badge: String?) -> NSImage {
    let base = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
      let body = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
      let top = NSColor.systemOrange.blended(withFraction: 0.25, of: .white) ?? .systemOrange
      let bottom = NSColor.systemOrange.blended(withFraction: 0.2, of: .brown) ?? .systemOrange
      NSGradient(starting: top, ending: bottom)?.draw(in: body, angle: -90)
      let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .medium)
      if let mark = NSImage(systemSymbolName: "asterisk", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: mark.size, flipped: false) { markRect in
          mark.draw(in: markRect)
          NSColor.white.withAlphaComponent(0.92).set()
          markRect.fill(using: .sourceAtop)
          return true
        }
        let origin = NSPoint(x: (canvas - mark.size.width) / 2, y: (canvas - mark.size.height) / 2 + 150)
        tinted.draw(in: NSRect(origin: origin, size: mark.size))
      }
      return true
    }
    guard let badge else { return base }
    var rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    guard let cg = base.cgImage(forProposedRect: &rect, context: nil, hints: nil),
          let composed = try? BadgeCompositor.compose(base: cg, style: .standard(label: badge))
    else { return base }
    return NSImage(cgImage: composed, size: NSSize(width: canvas, height: canvas))
  }

  static func pngData(badge: String?) throws -> Data {
    var rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    guard let cg = image(badge: badge).cgImage(forProposedRect: &rect, context: nil, hints: nil),
          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    else { throw SnapshotError.encodingFailed }
    return data
  }
}
