import AppKit
import QuartzCore

/// The mark on the status item, in the gap the glyph leaves for it: a red dot in a white ring while a clone is behind;
/// while an update runs, an open red ring with a white outline that turns slowly in its place. With Reduce Motion the
/// ring stays still: its open shape alone says «working». Not part of the template image, so it keeps its colours on
/// any menu bar.
final class StatusDotView: NSView {
  enum Mode: Equatable {
    case dot, spinner
  }

  /// The view's side: room for the ringed dot and for the outlined spinner.
  static let side = max(StatusGlyph.dotOuterDiameter, StatusGlyph.spinnerOuterDiameter)
  static let spinKey = "spin"
  /// One turn. The spin only has to read as «working», so it runs at a low frame rate.
  static let turn: CFTimeInterval = 1.2

  var mode: Mode = .dot {
    didSet {
      guard mode != oldValue else { return }
      needsDisplay = true
    }
  }

  private let dotLayer = CALayer()
  /// Turns as a whole: the white outline under the red line.
  private let spinnerLayer = CALayer()
  private let outlineLayer = CAShapeLayer()
  private let ringLayer = CAShapeLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  /// The ring is turning.
  var isSpinning: Bool { spinnerLayer.animation(forKey: Self.spinKey) != nil }

  override func updateLayer() {
    guard let layer else { return }
    if dotLayer.superlayer == nil {
      layer.addSublayer(dotLayer)
      spinnerLayer.addSublayer(outlineLayer)
      spinnerLayer.addSublayer(ringLayer)
      layer.addSublayer(spinnerLayer)
    }
    // Resolved here, in the menu bar's appearance.
    let red = StatusGlyph.dotFill.cgColor
    let white = StatusGlyph.dotRing.cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // The border is drawn inside the frame: the red fill keeps `dotDiameter`, the white ring goes around it.
    dotLayer.frame = centered(StatusGlyph.dotOuterDiameter)
    dotLayer.cornerRadius = StatusGlyph.dotOuterDiameter / 2
    dotLayer.backgroundColor = red
    dotLayer.borderColor = white
    dotLayer.borderWidth = StatusGlyph.dotRingWidth
    dotLayer.isHidden = mode != .dot
    spinnerLayer.frame = centered(StatusGlyph.spinnerOuterDiameter)
    let path = Self.ringPath(in: spinnerLayer.bounds)
    style(outlineLayer, path: path, color: white, width: StatusGlyph.spinnerLineWidth + 2 * StatusGlyph.spinnerOutlineWidth)
    style(ringLayer, path: path, color: red, width: StatusGlyph.spinnerLineWidth)
    spinnerLayer.isHidden = mode != .spinner
    CATransaction.commit()
    updateSpin()
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }

  /// Three quarters of a circle from the top, clockwise (the gap is top-left), centred in `rect`, with the red line's
  /// outer edge at `spinnerDiameter`.
  static func ringPath(in rect: CGRect) -> CGPath {
    let radius = (StatusGlyph.spinnerDiameter - StatusGlyph.spinnerLineWidth) / 2
    let start = CGFloat.pi / 2
    let path = CGMutablePath()
    path.addArc(
      center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: start,
      endAngle: start - 2 * .pi * StatusGlyph.spinnerSweep, clockwise: true)
    return path
  }

  private func style(_ shape: CAShapeLayer, path: CGPath, color: CGColor, width: CGFloat) {
    shape.frame = spinnerLayer.bounds
    shape.path = path
    shape.fillColor = nil
    shape.strokeColor = color
    shape.lineWidth = width
    shape.lineCap = .round
  }

  private func centered(_ diameter: CGFloat) -> CGRect {
    CGRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
  }

  /// A rotation only (compositor work), none when the user asked to reduce motion.
  private func updateSpin() {
    let spins = mode == .spinner && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if spins, !isSpinning {
      let spin = CABasicAnimation(keyPath: "transform.rotation.z")
      spin.fromValue = 0
      // Clockwise in the layer's y-up space.
      spin.toValue = -2 * CGFloat.pi
      spin.duration = Self.turn
      spin.repeatCount = .infinity
      spin.isRemovedOnCompletion = false
      spin.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
      spinnerLayer.add(spin, forKey: Self.spinKey)
    } else if !spins, isSpinning {
      spinnerLayer.removeAnimation(forKey: Self.spinKey)
    }
  }
}
