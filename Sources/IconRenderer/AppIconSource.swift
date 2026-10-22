import AppKit
import CoreGraphics
import Foundation

/// Supplies the base image for a clone's badge from an installed app's registered icon.
public protocol AppIconProviding: Sendable {
  /// The app icon rendered at `pixels` × `pixels` into sRGB, or `nil` when nothing ≥ `minimumPixels` exists.
  func renderedIcon(appURL: URL, pixels: Int, minimumPixels: Int) -> CGImage?
}

/// Renders the icon LaunchServices shows for an app (`NSWorkspace.icon(forFile:)`), which on macOS 26 is the
/// Assets.car icon rather than the legacy `electron.icns`.
/// Callers must pass ONLY the official, already registered source app — never a staged clone (G4).
public enum AppIconSource {
  public static func rendered(appURL: URL, pixels: Int, minimumPixels: Int = 512) -> CGImage? {
    let image = NSWorkspace.shared.icon(forFile: appURL.path)
    let sizes = image.representations.map(\.pixelsWide)
    guard isLargeEnough(representationPixels: sizes, minimumPixels: minimumPixels),
          let context = BitmapIO.makeContext(width: pixels, height: pixels)
    else { return nil }
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let result = context.makeImage(), hasVisiblePixels(result) else { return nil }
    return result
  }

  static func isLargeEnough(representationPixels: [Int], minimumPixels: Int) -> Bool {
    (representationPixels.max() ?? 0) >= minimumPixels
  }

  /// Whether any pixel has non-zero alpha (a fully transparent render means the icon was not available).
  static func hasVisiblePixels(_ image: CGImage) -> Bool {
    guard let context = BitmapIO.makeContext(width: image.width, height: image.height) else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else { return false }
    let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
    for row in 0..<image.height {
      for column in 0..<image.width where bytes[row * context.bytesPerRow + column * 4 + 3] != 0 {
        return true
      }
    }
    return false
  }
}

/// Production provider backed by `AppIconSource`.
public struct WorkspaceAppIconProvider: AppIconProviding {
  public init() {}

  public func renderedIcon(appURL: URL, pixels: Int, minimumPixels: Int) -> CGImage? {
    AppIconSource.rendered(appURL: appURL, pixels: pixels, minimumPixels: minimumPixels)
  }
}
