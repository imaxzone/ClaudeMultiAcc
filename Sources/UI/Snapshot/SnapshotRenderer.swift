import AppKit
import SwiftUI

public enum SnapshotError: Error, Equatable {
  case emptySize
  case bitmapUnavailable
  case encodingFailed
}

/// Renders SwiftUI views offscreen to PNG with a given appearance and scale (tests and review artifacts).
@MainActor
public enum SnapshotRenderer {
  public static func png<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name, scale: CGFloat) throws -> Data {
    guard size.width > 0, size.height > 0, scale > 0 else { throw SnapshotError.emptySize }
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = CGRect(origin: .zero, size: size)
    return try png(nsView: host, appearance: appearance, scale: scale)
  }

  /// Renders an AppKit view at its current frame size (menu snapshots mix hosted and standard rows).
  public static func png(nsView view: NSView, appearance: NSAppearance.Name, scale: CGFloat) throws -> Data {
    let size = view.frame.size
    guard size.width > 0, size.height > 0, scale > 0 else { throw SnapshotError.emptySize }
    let named = NSAppearance(named: appearance)
    view.appearance = named
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
                          defer: true)
    window.appearance = named
    window.isReleasedWhenClosed = false
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
    else { throw SnapshotError.bitmapUnavailable }
    rep.size = size
    (named ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: rep)
    }
    window.contentView = nil
    guard let data = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.encodingFailed }
    return data
  }

  /// A whole window with its title bar and toolbar (its frame view), never ordered in.
  public static func png(window: NSWindow, appearance: NSAppearance.Name, scale: CGFloat) throws -> Data {
    let named = NSAppearance(named: appearance)
    window.appearance = named
    guard let frameView = window.contentView?.superview else { throw SnapshotError.bitmapUnavailable }
    frameView.layoutSubtreeIfNeeded()
    let size = frameView.bounds.size
    guard size.width > 0, size.height > 0, scale > 0 else { throw SnapshotError.emptySize }
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)
    else { throw SnapshotError.bitmapUnavailable }
    rep.size = size
    (named ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
      frameView.cacheDisplay(in: frameView.bounds, to: rep)
    }
    guard let data = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.encodingFailed }
    return data
  }

  /// The height `view` wants at `width`, rounded up to whole points.
  public static func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
    let host = NSHostingView(rootView: view.frame(width: width))
    return host.fittingSize.height.rounded(.up)
  }
}
