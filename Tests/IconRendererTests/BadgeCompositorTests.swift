import CoreGraphics
import Foundation
import Support
import Testing
@testable import IconRenderer

/// RGBA8 pixel read back from an image rendered into an sRGB buffer; `y` counts from the bottom (AppKit origin).
struct Pixel: Equatable, CustomStringConvertible {
  let r: Int, g: Int, b: Int, a: Int
  var description: String { "(\(r), \(g), \(b), \(a))" }

  func isClose(to other: Pixel, tolerance: Int) -> Bool {
    abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance
      && abs(b - other.b) <= tolerance && abs(a - other.a) <= tolerance
  }
}

/// A decoded image with random pixel access in bottom-left-origin coordinates.
struct PixelBuffer {
  let width: Int, height: Int
  private let bytes: [UInt8]

  init(_ image: CGImage) throws {
    width = image.width
    height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let drawn: Bool = data.withUnsafeMutableBytes { raw in
      guard let context = CGContext(
        data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    try #require(drawn)
    bytes = data
  }

  func pixel(x: Int, y: Int) -> Pixel {
    let offset = ((height - 1 - y) * width + x) * 4
    return Pixel(r: Int(bytes[offset]), g: Int(bytes[offset + 1]), b: Int(bytes[offset + 2]), a: Int(bytes[offset + 3]))
  }
}

enum TestImages {
  /// An opaque 1024² image of one colour.
  static func solid(r: Int, g: Int, b: Int, side: Int = 1024) throws -> CGImage {
    try draw(side: side) { context in
      context.setFillColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
  }

  /// An opaque 1024² image with a smooth two-axis gradient, so every region has distinct pixels.
  static func gradient(side: Int = 1024) throws -> CGImage {
    try draw(side: side) { context in
      let space = CGColorSpace(name: CGColorSpace.sRGB)
      let colors = [CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1),
                    CGColor(srgbRed: 0.9, green: 0.8, blue: 0.2, alpha: 1)] as CFArray
      guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
      context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
    }
  }

  /// A rounded-square "app icon" on a transparent canvas, roughly like a macOS icon grid (the real Claude icon is
  /// opaque over px 100…923 of 1024). `inset` is a fraction of the side, `radius` in pixels.
  static func appIconLike(side: Int = 1024, inset: CGFloat = 0.1, radius: CGFloat = 185) throws -> CGImage {
    try draw(side: side) { context in
      let margin = CGFloat(side) * inset
      let rect = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: margin, dy: margin)
      context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.setFillColor(CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1))
      context.fillPath()
    }
  }

  /// A fully transparent canvas (no icon body at all).
  static func transparent(side: Int = 1024) throws -> CGImage {
    try draw(side: side) { _ in }
  }

  private static func draw(side: Int, _ body: (CGContext) -> Void) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    body(context)
    return try #require(context.makeImage())
  }
}

/// PNG artifacts for eyeballing go to `ArtifactsDir.url/icons/`.
func writeIconArtifact(_ image: CGImage, name: String) throws -> URL {
  let dir = ArtifactsDir.url.appendingPathComponent("icons", isDirectory: true)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let url = dir.appendingPathComponent(name)
  try BitmapIO.pngData(image).write(to: url)
  return url
}

@Suite struct BadgeCompositorTests {
  static let fill = Pixel(r: 0xA8, g: 0x3A, b: 0x0E, a: 255)
  static let white = Pixel(r: 255, g: 255, b: 255, a: 255)

  @Test func standardStyleKeepsTheOriginalLookInsideTheIconShape() {
    let style = BadgeStyle.standard(label: "2nd")
    #expect(style.label == "2nd")
    #expect(style.fillHex == "#A83A0E")
    #expect(style.fontPx == 194)
    #expect(style.canvas == 1024)
    #expect(style.bottomInset == 115)
    #expect(style.maxPillWidth == 600)
  }

  @Test func pillGeometryFollowsTheFontSize() throws {
    let layout = try BadgeCompositor.layout(style: .standard(label: "2nd"))
    #expect(layout.font.pointSize == 194)
    #expect(abs(layout.pill.height - 194 * 1.34) < 0.001)
    #expect(abs(layout.pill.width - (layout.textSize.width + 194 * 0.9)) < 0.001)
    #expect(abs(layout.pill.midX - 512) < 0.001)
    // R1: the pill's outer edge (stroke included) sits 115 px above the canvas bottom, inside the icon body
    // (px 100…923), and stays in the lower part of the icon.
    #expect(abs(layout.outer.minY - 115) < 0.001)
    #expect(layout.outer.width <= 600)
    #expect(layout.outer.maxY / 1024 < 0.4)
  }

  /// Long labels get a smaller font so the pill stays at most 600 px wide; it keeps its bottom edge.
  @Test(arguments: ["Работа", "5x акк", "WWWWWW", "abcdef"])
  func longLabelsShrinkTheFont(label: String) throws {
    let layout = try BadgeCompositor.layout(style: .standard(label: label))
    #expect(layout.font.pointSize < 194, "\(label): \(layout.font.pointSize)")
    #expect(layout.outer.width <= 600 && layout.outer.width > 590, "\(label): \(layout.outer.width)")
    #expect(abs(layout.outer.minY - 115) < 0.001)
    #expect(abs(layout.pill.midX - 512) < 0.001)
  }

  /// R1: macOS 26+ jails an icon whose opaque pixels leave its shape. Every badge pixel with alpha ≥ 128 lies where
  /// the base is opaque (alpha ≥ 250), at the standard size; outside the base silhouette nothing changes.
  @Test(arguments: ["2nd", "mv2", "5x", "Работа", "5x акк", "WWWWWW"])
  func badgeStaysInsideTheIconShape(label: String) throws {
    for base in [try TestImages.appIconLike(), try TestImages.appIconLike(inset: 100 / 1024, radius: 230)] {
      let fit = try BadgeCompositor.fit(base: base, style: .standard(label: label))
      #expect(fit.scale == 1, "\(label) needed a retry")
      let outside = try Self.badgePixelsOutsideTheBody(layer: fit.layer, base: base)
      #expect(outside == 0, "\(label): \(outside) badge pixels outside the icon body")
      let result = try PixelBuffer(BadgeCompositor.compose(base: base, style: .standard(label: label)))
      let original = try PixelBuffer(base)
      var grown = 0
      for y in 0..<1024 {
        for x in 0..<1024 where original.pixel(x: x, y: y).a == 0 && result.pixel(x: x, y: y).a != 0 { grown += 1 }
      }
      #expect(grown == 0, "\(label): \(grown) pixels painted outside the base silhouette")
    }
  }

  /// A smaller icon body: the self-check shrinks the badge towards the centre (lifting its bottom edge) until it fits.
  @Test func shrinksAndRetriesWhenTheBadgeWouldLeaveTheShape() throws {
    let base = try TestImages.appIconLike(inset: 0.2, radius: 160)
    let fit = try BadgeCompositor.fit(base: base, style: .standard(label: "mv2"))
    #expect(fit.scale < 1)
    #expect(fit.layout.outer.minY > 115)
    #expect(try Self.badgePixelsOutsideTheBody(layer: fit.layer, base: base) == 0)
  }

  @Test func throwsWhenTheBadgeCannotFitTheIcon() throws {
    let base = try TestImages.transparent()
    #expect(throws: BadgeError.badgeOutsideIcon) {
      try BadgeCompositor.compose(base: base, style: .standard(label: "2nd"))
    }
  }

  /// Badge-layer pixels with alpha ≥ 128 where the base alpha is below 250 (independent of the compositor's check).
  static func badgePixelsOutsideTheBody(layer: CGImage, base: CGImage) throws -> Int {
    let (badge, body) = (try PixelBuffer(layer), try PixelBuffer(base))
    var count = 0
    for y in 0..<badge.height {
      for x in 0..<badge.width where badge.pixel(x: x, y: y).a >= 128 && body.pixel(x: x, y: y).a < 250 { count += 1 }
    }
    return count
  }

  @Test func compositeKeepsCornersAndPaintsThePill() throws {
    let base = try TestImages.solid(r: 40, g: 120, b: 200)
    let style = BadgeStyle.standard(label: "2nd")
    let result = try BadgeCompositor.compose(base: base, style: style)
    #expect(result.width == 1024 && result.height == 1024)

    let pixels = try PixelBuffer(result)
    let baseColor = Pixel(r: 40, g: 120, b: 200, a: 255)
    for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (512, 900)] {
      #expect(pixels.pixel(x: x, y: y) == baseColor, "corner (\(x), \(y))")
    }

    let pill = try BadgeCompositor.layout(style: style).pill
    let fillSample = pixels.pixel(x: Int(pill.minX + 45), y: Int(pill.midY))
    #expect(fillSample.isClose(to: Self.fill, tolerance: 3), "fill \(fillSample)")
    let strokeSample = pixels.pixel(x: Int(pill.midX), y: Int(pill.minY))
    #expect(strokeSample.isClose(to: Self.white, tolerance: 3), "stroke \(strokeSample)")
    let topStroke = pixels.pixel(x: Int(pill.midX), y: Int(pill.maxY) - 1)
    #expect(topStroke.isClose(to: Self.white, tolerance: 3), "top stroke \(topStroke)")
  }

  @Test func baseImageIsScaledToFillTheCanvas() throws {
    let base = try TestImages.solid(r: 10, g: 200, b: 30, side: 256)
    let result = try BadgeCompositor.compose(base: base, style: .standard(label: "2nd"))
    let pixels = try PixelBuffer(result)
    #expect(result.width == 1024)
    #expect(pixels.pixel(x: 1023, y: 1023) == Pixel(r: 10, g: 200, b: 30, a: 255))
  }

  @Test(arguments: ["1234567", "stagetest"])
  func labelTooLongThrows(label: String) throws {
    let base = try TestImages.solid(r: 0, g: 0, b: 0)
    #expect(throws: BadgeError.labelTooLong(label.count)) {
      try BadgeCompositor.compose(base: base, style: .standard(label: label))
    }
  }

  @Test func emptyLabelThrows() throws {
    let base = try TestImages.solid(r: 0, g: 0, b: 0)
    #expect(throws: BadgeError.labelEmpty) {
      try BadgeCompositor.compose(base: base, style: .standard(label: ""))
    }
  }

  @Test func sixCharacterLabelIsAccepted() throws {
    let base = try TestImages.solid(r: 0, g: 0, b: 0)
    let result = try BadgeCompositor.compose(base: base, style: .standard(label: "abcdef"))
    #expect(result.width == 1024)
  }

  @Test func invalidFillHexThrows() throws {
    let base = try TestImages.solid(r: 0, g: 0, b: 0)
    var style = BadgeStyle.standard(label: "2nd")
    style.fillHex = "orange"
    #expect(throws: BadgeError.invalidFillHex("orange")) {
      try BadgeCompositor.compose(base: base, style: style)
    }
  }

  @Test func writesEyeballArtifacts() throws {
    let base = try TestImages.appIconLike()
    let second = try BadgeCompositor.compose(base: base, style: .standard(label: "2nd"))
    let stage = try BadgeCompositor.compose(base: base, style: .standard(label: "test"))
    for (image, name) in [(second, "badge-2nd.png"), (stage, "badge-stagetest.png")] {
      let url = try writeIconArtifact(image, name: name)
      let reloaded = try BitmapIO.load(url)
      #expect(reloaded.width == 1024 && reloaded.height == 1024)
    }
  }

  @Test func loadingGarbageThrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmacc-garbage-\(UUID().uuidString).png")
    try Data("not a png".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: BitmapIOError.decodeFailed(url.path)) { try BitmapIO.load(url) }
  }
}
