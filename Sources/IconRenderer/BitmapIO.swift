import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum BitmapIOError: Error, Equatable {
  case encodeFailed
  case decodeFailed(String)
}

/// PNG encoding and image decoding through ImageIO (no AppKit, no Finder icon APIs).
public enum BitmapIO {
  public static func pngData(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw BitmapIOError.encodeFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw BitmapIOError.encodeFailed }
    return data as Data
  }

  public static func load(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw BitmapIOError.decodeFailed(url.path) }
    return image
  }

  /// An opaque-or-alpha sRGB RGBA8 context of `width` × `height` pixels.
  static func makeContext(width: Int, height: Int) -> CGContext? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  /// `image` redrawn at `side` × `side` pixels with high-quality interpolation.
  static func resized(_ image: CGImage, side: Int) throws -> CGImage {
    guard let context = makeContext(width: side, height: side) else { throw BitmapIOError.encodeFailed }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let result = context.makeImage() else { throw BitmapIOError.encodeFailed }
    return result
  }
}
