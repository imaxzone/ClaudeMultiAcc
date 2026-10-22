import Foundation
import Testing
@testable import IconRenderer

/// Builds `.icns` bytes by hand: `icns` + big-endian total length, then each entry's type, big-endian length
/// (8-byte entry header included) and payload.
enum IcnsBytes {
  static func make(_ entries: [(type: String, payload: Data)]) -> Data {
    let body = entries.reduce(Data()) { data, entry in
      data + Data(entry.type.utf8) + bigEndian(entry.payload.count + 8) + entry.payload
    }
    return Data("icns".utf8) + bigEndian(body.count + 8) + body
  }

  static func make(types: [String]) -> Data {
    make(types.map { ($0, Data("png".utf8)) })
  }

  static func bigEndian(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
  }
}

@Suite struct IcnsFileTests {
  @Test func readsTheTypesInFileOrder() throws {
    let data = IcnsBytes.make([("ic12", Data(repeating: 1, count: 40)), ("info", Data("plist".utf8)), ("ic07", Data())])
    #expect(try IcnsFile.entryTypes(of: data) == ["ic12", "info", "ic07"])
    #expect(try IcnsFile.imageTypes(of: data) == ["ic12", "ic07"])
  }

  @Test func imageTypesLeaveOutEveryMetadataEntry() throws {
    let data = IcnsBytes.make(types: ["TOC ", "icnV", "ic10", "info", "ic09"])
    #expect(try IcnsFile.imageTypes(of: data) == ["ic10", "ic09"])
  }

  @Test func readsAFileWithNoEntries() throws {
    #expect(try IcnsFile.entryTypes(of: IcnsBytes.make([])) == [])
  }

  @Test(arguments: [Data(), Data("icns".utf8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 16])])
  func rejectsDataThatIsNotAnIcnsFile(data: Data) {
    #expect(throws: IcnsFileError.notIcns) { try IcnsFile.entryTypes(of: data) }
  }

  /// The old fake marker `icns-badged` starts with the magic but declares a length far beyond its 11 bytes.
  @Test func rejectsATotalLengthBeyondTheData() {
    #expect(throws: IcnsFileError.malformed(offset: 4)) { try IcnsFile.entryTypes(of: Data("icns-badged".utf8)) }
  }

  @Test func rejectsAnEntryRunningPastTheFile() {
    var data = IcnsBytes.make(types: ["ic07"])
    data.replaceSubrange(12..<16, with: IcnsBytes.bigEndian(4096))
    #expect(throws: IcnsFileError.malformed(offset: 8)) { try IcnsFile.entryTypes(of: data) }
  }

  /// A length below the 8-byte entry header would never advance; it is rejected instead of looping.
  @Test func rejectsAnEntryShorterThanItsHeader() {
    var data = IcnsBytes.make(types: ["ic07", "ic08"])
    data.replaceSubrange(23..<27, with: IcnsBytes.bigEndian(0))
    #expect(throws: IcnsFileError.malformed(offset: 19)) { try IcnsFile.entryTypes(of: data) }
  }

  @Test func rejectsATruncatedEntryHeader() {
    let data = IcnsBytes.make(types: ["ic07"]) + Data("ic0".utf8)
    var patched = data
    patched.replaceSubrange(4..<8, with: IcnsBytes.bigEndian(data.count))
    #expect(throws: IcnsFileError.malformed(offset: 19)) { try IcnsFile.entryTypes(of: patched) }
  }

  /// The 1× 16 and 32 pt slots in every encoding; none of the eight types `IcnsTool.writeIcns` produces.
  @Test func smallOneXTypesCoverThe1xSlotsOnly() {
    #expect(IcnsFile.smallOneXTypes.isSuperset(of: ["ic04", "ic05", "is32", "il32", "s8mk", "l8mk", "icp4", "icp5"]))
    #expect(IcnsFile.smallOneXTypes.isDisjoint(with: ["ic11", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]))
    #expect(IcnsFile.smallOneXTypes.isDisjoint(with: IcnsFile.metadataTypes))
  }
}
