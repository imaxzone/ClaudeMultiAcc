import Darwin
import Foundation
import Testing
@testable import InstanceBuilder

/// `CustomIconCheck` only reads: it recognises the Finder custom icon that clones built before the badge moved into
/// `electron.icns` still carry (`Icon\r` plus `com.apple.FinderInfo` on the bundle root).
@Suite struct CustomIconCheckTests {
  /// A clone folder with `Contents`, the given empty root files and, optionally, FinderInfo on the bundle root.
  private func app(rootFiles: [String], finderInfo: Bool, _ name: String = #function) throws -> URL {
    let app = try makeTempDir(name).appendingPathComponent("Claude Work.app", isDirectory: true)
    try MiniBundle.write(Data("<plist/>".utf8), app.appendingPathComponent("Contents/Info.plist"))
    for file in rootFiles { try Data().write(to: app.appendingPathComponent(file)) }
    if finderInfo {
      // The `kHasCustomIcon` Finder flag, as `NSWorkspace.setIcon` leaves it (an all-zero FinderInfo is dropped).
      var bytes = [UInt8](repeating: 0, count: 32)
      bytes[8] = 0x04
      #expect(setxattr(app.path, "com.apple.FinderInfo", bytes, bytes.count, 0, 0) == 0)
    }
    return app
  }

  @Test func recognisesTheCustomIconOfAnOldClone() throws {
    let inspection = CustomIconCheck.inspect(try app(rootFiles: [CustomIconCheck.iconFile], finderInfo: true))
    #expect(inspection == CustomIconCheck.Inspection(present: true, finderInfo: true, unsealedEntries: []))
    let (icon, root) = CustomIconCheck.checks(inspection)
    #expect(icon == SmokeCheck("custom-icon", true, "present (Icon\\r + FinderInfo; codesign run without --strict)"))
    #expect(root == SmokeCheck("bundle-root-sealed", true, "only Contents and Icon\\r"))
  }

  @Test func aCloneBuiltWithTheBadgeInsideHasNoCustomIcon() throws {
    let inspection = CustomIconCheck.inspect(try app(rootFiles: [], finderInfo: false))
    #expect(inspection == CustomIconCheck.Inspection(present: false, finderInfo: false, unsealedEntries: []))
  }

  @Test func otherRootEntriesAreReportedAsUnsealed() throws {
    let inspection = CustomIconCheck.inspect(try app(rootFiles: [CustomIconCheck.iconFile, "notes.txt"], finderInfo: false))
    #expect(inspection.unsealedEntries == ["notes.txt"])
    #expect(CustomIconCheck.checks(inspection).root == SmokeCheck("bundle-root-sealed", false, "unsealed: notes.txt"))
    #expect(CustomIconCheck.checks(inspection).icon.detail.contains("no FinderInfo"))
  }
}
