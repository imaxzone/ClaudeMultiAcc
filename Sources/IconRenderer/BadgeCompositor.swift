import AppKit

/// Where the badge parts land on the canvas (bottom-left origin, pixels = points).
struct BadgeLayout {
  let font: NSFont
  let text: NSAttributedString
  let textSize: CGSize
  /// The pill path; the white stroke (`strokeWidth`) is centred on it.
  let pill: CGRect
  let strokeWidth: CGFloat
  let textOrigin: CGPoint

  /// The pill with its stroke: the part that must stay inside the icon shape.
  var outer: CGRect { pill.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2) }
}

/// A layout that passed the containment self-check, with the badge layer drawn for it.
struct BadgeFit {
  let layout: BadgeLayout
  /// 1 for the standard geometry, `shrinkFactor`ⁿ after n retries.
  let scale: CGFloat
  /// The badge alone (shadowed pill, stroke, text) on a transparent canvas, before it is clipped to the icon.
  let layer: CGImage
}

/// Composites the pill badge onto a base icon image (the official app's icon, see `BadgeStep`). The drawing is a port
/// of the original badge prototype (shadowed fill, white stroke, white text) into an sRGB `CGContext`.
/// Self-check (R1): every badge pixel with alpha ≥ 128 must lie where the base is opaque (alpha ≥ 250); otherwise the
/// badge shrinks towards the canvas centre (as if drawn on a smaller icon body) and is drawn again, at most
/// `maxAttempts` times. The accepted badge is clipped to the base's silhouette, so not even its soft shadow reaches
/// past the icon.
public enum BadgeCompositor {
  static let pillHeightRatio: CGFloat = 1.34
  static let pillPaddingRatio: CGFloat = 0.9
  static let strokeRatio: CGFloat = 0.09
  static let shrinkFactor: CGFloat = 0.9
  static let maxAttempts = 6
  static let badgeAlphaFloor: UInt8 = 128
  static let bodyAlphaFloor: UInt8 = 250

  public static func compose(base: CGImage, style: BadgeStyle) throws -> CGImage {
    try style.validate()
    let canvas = try BaseCanvas(base: base, side: style.canvas)
    return try canvas.composited(with: fit(canvas: canvas, style: style).layer)
  }

  /// The largest layout whose badge stays on the opaque body of `base`; throws `BadgeError.badgeOutsideIcon`.
  static func fit(base: CGImage, style: BadgeStyle) throws -> BadgeFit {
    try style.validate()
    return try fit(canvas: BaseCanvas(base: base, side: style.canvas), style: style)
  }

  private static func fit(canvas: BaseCanvas, style: BadgeStyle) throws -> BadgeFit {
    let fill = try style.fillComponents()
    let color = NSColor(srgbRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1)
    var scale: CGFloat = 1
    for _ in 0..<maxAttempts {
      let layout = try layout(style: style, scale: scale)
      let (layer, mask) = try drawLayer(layout: layout, side: style.canvas, fill: color)
      if canvas.body.covers(mask, badgeFloor: badgeAlphaFloor, bodyFloor: bodyAlphaFloor) {
        return BadgeFit(layout: layout, scale: scale, layer: layer)
      }
      scale *= shrinkFactor
    }
    throw BadgeError.badgeOutsideIcon
  }

  /// Font, text and pill geometry for `style`, shrunk by `scale` towards the canvas centre; throws for invalid
  /// labels. At `scale` 1 the outer edge sits exactly `bottomInset` above the canvas bottom.
  static func layout(style: BadgeStyle, scale: CGFloat = 1) throws -> BadgeLayout {
    try style.validate()
    let fitted = fittedFontSize(style: style)
    let size = fitted * scale
    let font = roundedHeavy(size)
    let text = NSAttributedString(string: style.label, attributes: [.font: font, .foregroundColor: NSColor.white])
    let textSize = text.size()
    let (pillW, pillH) = (textSize.width + size * pillPaddingRatio, size * pillHeightRatio)
    let mid = CGFloat(style.canvas) / 2
    let centerY = mid + (style.bottomInset + fitted * (pillHeightRatio + strokeRatio) / 2 - mid) * scale
    let pill = CGRect(x: (CGFloat(style.canvas) - pillW) / 2, y: centerY - pillH / 2, width: pillW, height: pillH)
    let origin = CGPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2 - font.descender / 2)
    return BadgeLayout(
      font: font, text: text, textSize: textSize, pill: pill, strokeWidth: size * strokeRatio, textOrigin: origin)
  }

  /// `fontPx`, or the size at which the pill (stroke included) is just narrower than `maxPillWidth`.
  static func fittedFontSize(style: BadgeStyle) -> CGFloat {
    var size = style.fontPx
    for _ in 0..<4 {
      let width = outerWidth(label: style.label, size: size)
      guard width > style.maxPillWidth else { return size }
      size *= style.maxPillWidth / width * 0.999
    }
    return size
  }

  private static func outerWidth(label: String, size: CGFloat) -> CGFloat {
    let text = NSAttributedString(string: label, attributes: [.font: roundedHeavy(size)])
    return text.size().width + size * (pillPaddingRatio + strokeRatio)
  }

  private static func roundedHeavy(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
  }

  /// The badge alone on a transparent `side` × `side` canvas, and its alpha channel.
  private static func drawLayer(layout: BadgeLayout, side: Int, fill: NSColor) throws -> (CGImage, AlphaMask) {
    guard let context = BitmapIO.makeContext(width: side, height: side) else { throw BadgeError.drawingFailed }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    drawPill(layout: layout, fill: fill)
    layout.text.draw(at: layout.textOrigin)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { throw BadgeError.drawingFailed }
    return (image, try AlphaMask(context: context))
  }

  /// Shadowed fill, then a white stroke on top (the stroke itself casts no shadow), as in the original.
  private static func drawPill(layout: BadgeLayout, fill: NSColor) {
    let size = layout.font.pointSize
    let radius = layout.pill.height / 2
    let path = NSBezierPath(roundedRect: layout.pill, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = size * 0.12
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.05)
    shadow.set()
    fill.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.setStroke()
    path.lineWidth = layout.strokeWidth
    path.stroke()
  }
}

/// The base icon drawn at `side` × `side` pixels, with its alpha channel for the containment check.
private struct BaseCanvas {
  let side: Int
  let image: CGImage
  let body: AlphaMask

  init(base: CGImage, side: Int) throws {
    guard let context = BitmapIO.makeContext(width: side, height: side) else { throw BadgeError.drawingFailed }
    context.interpolationQuality = .high
    context.draw(base, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let image = context.makeImage() else { throw BadgeError.drawingFailed }
    self.side = side
    self.image = image
    body = try AlphaMask(context: context)
  }

  /// `layer` clipped to the base's silhouette (destination-in: its alpha times the base's), drawn over the base.
  func composited(with layer: CGImage) throws -> CGImage {
    let rect = CGRect(x: 0, y: 0, width: side, height: side)
    guard let clip = BitmapIO.makeContext(width: side, height: side),
          let out = BitmapIO.makeContext(width: side, height: side)
    else { throw BadgeError.drawingFailed }
    clip.draw(layer, in: rect)
    clip.setBlendMode(.destinationIn)
    clip.draw(image, in: rect)
    guard let clipped = clip.makeImage() else { throw BadgeError.drawingFailed }
    out.draw(image, in: rect)
    out.draw(clipped, in: rect)
    guard let result = out.makeImage() else { throw BadgeError.drawingFailed }
    return result
  }
}

/// One alpha byte per pixel of a square RGBA8 context (`BitmapIO.makeContext`), in memory order (row 0 on top).
private struct AlphaMask {
  let side: Int
  let alpha: [UInt8]

  init(context: CGContext) throws {
    guard let data = context.data, context.width == context.height else { throw BadgeError.drawingFailed }
    let (side, stride) = (context.width, context.bytesPerRow)
    let bytes = data.bindMemory(to: UInt8.self, capacity: stride * side)
    var alpha = [UInt8](repeating: 0, count: side * side)
    for row in 0..<side {
      for column in 0..<side { alpha[row * side + column] = bytes[row * stride + column * 4 + 3] }
    }
    self.side = side
    self.alpha = alpha
  }

  /// Whether every pixel of `badge` with alpha ≥ `badgeFloor` lies where this mask has alpha ≥ `bodyFloor`.
  func covers(_ badge: AlphaMask, badgeFloor: UInt8, bodyFloor: UInt8) -> Bool {
    guard badge.side == side else { return false }
    return !zip(badge.alpha, alpha).contains { $0 >= badgeFloor && $1 < bodyFloor }
  }
}
