import AppKit
import QuartzCore

/// The blue mark on the status item, in the gap the glyph leaves for it: a dot while a clone is behind; while an
/// update runs, an open ring that turns slowly in its place. With Reduce Motion the ring stays still: its open shape
/// alone says «working». Not part of the template image, so it keeps the update blue on any menu bar.
final class StatusDotView: NSView {
  enum Mode: Equatable {
    case dot, spinner
  }

  /// The view's side: room for the dot and for the slightly larger ring.
  static let side = max(StatusGlyph.dotDiameter, StatusGlyph.spinnerDiameter)
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
  var isSpinning: Bool { ringLayer.animation(forKey: Self.spinKey) != nil }

  override func updateLayer() {
    guard let layer else { return }
    if dotLayer.superlayer == nil {
      layer.addSublayer(dotLayer)
      layer.addSublayer(ringLayer)
    }
    // Resolved here, in the menu bar's appearance.
    let blue = NSColor.systemBlue.cgColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    dotLayer.frame = centered(StatusGlyph.dotDiameter)
    dotLayer.cornerRadius = StatusGlyph.dotDiameter / 2
    dotLayer.backgroundColor = blue
    dotLayer.isHidden = mode != .dot
    ringLayer.frame = centered(StatusGlyph.spinnerDiameter)
    ringLayer.path = Self.ringPath(in: ringLayer.bounds)
    ringLayer.fillColor = nil
    ringLayer.strokeColor = blue
    ringLayer.lineWidth = StatusGlyph.spinnerLineWidth
    ringLayer.lineCap = .round
    ringLayer.isHidden = mode != .spinner
    CATransaction.commit()
    updateSpin()
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }

  /// Three quarters of a circle from the top, clockwise (the gap is top-left), centred in `rect`.
  static func ringPath(in rect: CGRect) -> CGPath {
    let radius = (min(rect.width, rect.height) - StatusGlyph.spinnerLineWidth) / 2
    let start = CGFloat.pi / 2
    let path = CGMutablePath()
    path.addArc(
      center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: start,
      endAngle: start - 2 * .pi * StatusGlyph.spinnerSweep, clockwise: true)
    return path
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
      ringLayer.add(spin, forKey: Self.spinKey)
    } else if !spins, isSpinning {
      ringLayer.removeAnimation(forKey: Self.spinKey)
    }
  }
}
