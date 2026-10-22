import CoreGraphics
import Foundation

/// The pill badge baked into a clone's `electron.icns` at build time (`BadgeStep`): the look of the original badge
/// prototype (194 px heavy rounded type, dark terracotta pill with a white stroke, P10), placed so it always stays
/// inside the icon shape. macOS 26+ puts an icon on a grey plate when opaque pixels stick out of its rounded square
/// (px 100…923 of 1024, R1), so the pill's outer edge sits at least `bottomInset` px above the canvas bottom and is at
/// most `maxPillWidth` px wide (long labels get a smaller font).
public struct BadgeStyle: Sendable, Equatable {
  public static let maxLabelLength = 6

  public var label: String
  public var fillHex: String = "#A83A0E"
  public var fontPx: CGFloat = 194
  public var canvas: Int = 1024
  /// Distance from the canvas bottom to the pill's outer edge (stroke included).
  public var bottomInset: CGFloat = 115
  /// The widest the pill may be, stroke included; a longer label shrinks the font below `fontPx`.
  public var maxPillWidth: CGFloat = 600

  public init(label: String) {
    self.label = label
  }

  public static func standard(label: String) -> BadgeStyle {
    BadgeStyle(label: label)
  }

  /// Throws when the label is empty or longer than `maxLabelLength` characters.
  func validate() throws {
    guard !label.isEmpty else { throw BadgeError.labelEmpty }
    guard label.count <= Self.maxLabelLength else { throw BadgeError.labelTooLong(label.count) }
  }

  /// The fill colour as sRGB components 0…1; accepts `#RRGGBB` or `RRGGBB`.
  func fillComponents() throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
    let digits = fillHex.hasPrefix("#") ? String(fillHex.dropFirst()) : fillHex
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else {
      throw BadgeError.invalidFillHex(fillHex)
    }
    return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
  }
}

public enum BadgeError: Error, Equatable {
  case labelEmpty
  case labelTooLong(Int)
  case invalidFillHex(String)
  case drawingFailed
  /// Even the smallest retry left opaque badge pixels outside the icon body (a base without a usable shape).
  case badgeOutsideIcon
}
