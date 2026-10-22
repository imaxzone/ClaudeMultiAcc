import Foundation

public enum IcnsFileError: Error, Equatable {
  case notIcns
  /// The length field at `offset` points outside the file or below the 8-byte entry header.
  case malformed(offset: Int)
}

/// Reads the entry list of an `.icns` file without decoding any image: an 8-byte header (`icns` + big-endian total
/// length), then entries of a 4-byte type, a 4-byte big-endian length (those 8 bytes included) and the payload.
public enum IcnsFile {
  /// Entries that hold no image: the table of contents, the version and the plist `iconutil` adds.
  public static let metadataTypes: Set<String> = ["TOC ", "icnV", "info"]

  /// Every type drawn at 1× for 16 or 32 pt: `ic04`/`ic05` (what `iconutil` writes for `icon_16x16`/`icon_32x32`),
  /// `icp4`/`icp5`, the RLE `is32`/`il32` with their `s8mk`/`l8mk` masks and the classic 1/4/8-bit icons. Any of them
  /// puts a `CFBundleIconFile` icon on macOS 26+'s grey legacy platter at ≤ 32 pt 1× (see `IcnsTool.iconsetEntries`).
  public static let smallOneXTypes: Set<String> = [
    "ic04", "ic05", "icp4", "icp5", "is32", "il32", "s8mk", "l8mk",
    "ICON", "ICN#", "ics#", "icm#", "ics4", "icl4", "icm4", "ics8", "icl8", "icm8",
  ]

  /// The type codes in file order, metadata included.
  public static func entryTypes(of data: Data) throws -> [String] {
    let bytes = [UInt8](data)
    guard bytes.count >= 8, bytes[0..<4].elementsEqual("icns".utf8) else { throw IcnsFileError.notIcns }
    let total = Int(bigEndian32(bytes, at: 4))
    guard total >= 8, total <= bytes.count else { throw IcnsFileError.malformed(offset: 4) }
    var types: [String] = []
    var offset = 8
    while offset < total {
      guard offset + 8 <= total else { throw IcnsFileError.malformed(offset: offset) }
      let length = Int(bigEndian32(bytes, at: offset + 4))
      guard length >= 8, length <= total - offset else { throw IcnsFileError.malformed(offset: offset) }
      types.append(String(bytes[offset..<offset + 4].map { Character(Unicode.Scalar($0)) }))
      offset += length
    }
    return types
  }

  /// The image type codes in file order (`metadataTypes` left out).
  public static func imageTypes(of data: Data) throws -> [String] {
    try entryTypes(of: data).filter { !metadataTypes.contains($0) }
  }

  private static func bigEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }
}
