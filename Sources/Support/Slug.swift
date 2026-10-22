import Foundation

public enum SlugError: Error, Equatable {
  case invalid(String)
}

/// Identifier of one account/instance: `^[a-z0-9][a-z0-9-]{0,31}$` (G1).
public struct Slug: Hashable, Codable, Sendable, CustomStringConvertible {
  public let raw: String

  public init(_ raw: String) throws {
    guard Self.isValid(raw) else { throw SlugError.invalid(raw) }
    self.raw = raw
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard Self.isValid(raw) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid slug '\(raw)'")
    }
    self.raw = raw
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(raw)
  }

  public var description: String { raw }

  static func isValid(_ raw: String) -> Bool {
    let bytes = Array(raw.utf8)
    guard (1...32).contains(bytes.count), let first = bytes.first, isLowerAlnum(first) else { return false }
    return bytes.dropFirst().allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: "-") }
  }

  private static func isLowerAlnum(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }
}
