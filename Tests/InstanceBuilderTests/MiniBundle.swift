import Foundation
import Testing
@testable import InstanceBuilder

/// A small on-disk stand-in for `/Applications/Claude.app` with the parts the builder touches.
enum MiniBundle {
  static let helperId = "com.anthropic.claudefordesktop.helper"
  static let machOBytes = Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])

  /// `executable` is the content of `Contents/MacOS/Claude`, the helper binary and ShipIt
  /// (fake Mach-O magic by default; tests that sign pass a real binary).
  @discardableResult
  static func makeSource(in dir: URL, executable: Data = machOBytes, icns: Data = Data("icns-original".utf8)) throws -> URL {
    let app = dir.appendingPathComponent("Claude.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents")
    try write(try fixtureData("Info-claude.plist"), contents.appendingPathComponent("Info.plist"))
    try write(executable, contents.appendingPathComponent("MacOS/Claude"), mode: 0o755)
    try write(icns, contents.appendingPathComponent("Resources/electron.icns"))
    try write(Data("profile".utf8), contents.appendingPathComponent("embedded.provisionprofile"))
    try write(Data("ticket".utf8), contents.appendingPathComponent("CodeResources"))
    try write(Data(), app.appendingPathComponent("Icon\r"))
    try makeHelper(in: contents.appendingPathComponent("Frameworks"), executable: executable)
    try makeSquirrel(in: contents.appendingPathComponent("Frameworks"), executable: executable)
    return app
  }

  static func makeHelper(in frameworks: URL, executable: Data) throws {
    let helper = frameworks.appendingPathComponent("Claude Helper.app/Contents")
    let info: [String: Any] = [
      "CFBundleIdentifier": helperId, "CFBundleName": "Claude Helper", "CFBundleExecutable": "Claude Helper",
      "CFBundlePackageType": "APPL",
    ]
    try write(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
              helper.appendingPathComponent("Info.plist"))
    try write(executable, helper.appendingPathComponent("MacOS/Claude Helper"), mode: 0o755)
  }

  static func makeSquirrel(in frameworks: URL, executable: Data) throws {
    let framework = frameworks.appendingPathComponent("Squirrel.framework")
    let versionA = framework.appendingPathComponent("Versions/A")
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.github.Squirrel", "CFBundleName": "Squirrel", "CFBundleExecutable": "Squirrel",
      "CFBundlePackageType": "FMWK",
    ]
    try write(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
              versionA.appendingPathComponent("Resources/Info.plist"))
    try write(executable, versionA.appendingPathComponent("Squirrel"), mode: 0o755)
    try write(executable, versionA.appendingPathComponent("Resources/ShipIt"), mode: 0o755)
    let fm = FileManager.default
    try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
    try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Squirrel").path,
                              withDestinationPath: "Versions/Current/Squirrel")
    try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path,
                              withDestinationPath: "Versions/Current/Resources")
  }

  /// Every entry under `root` by relative path: `dir`, `-> <target>` for symlinks (never followed), or the file's
  /// SHA-256 and POSIX mode. Two equal digests mean byte-identical trees.
  static func treeDigest(_ root: URL) throws -> [String: String] {
    let fm = FileManager.default
    let entries = try #require(fm.enumerator(atPath: root.path)).compactMap { $0 as? String }
    var digest: [String: String] = [:]
    for relative in entries {
      let url = root.appendingPathComponent(relative)
      let attributes = try fm.attributesOfItem(atPath: url.path)
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory?: digest[relative] = "dir"
      case .typeSymbolicLink?: digest[relative] = "-> " + (try fm.destinationOfSymbolicLink(atPath: url.path))
      default:
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        digest[relative] = "\(StaticSmoke.sha256(of: url) ?? "unreadable") \(String(mode, radix: 8))"
      }
    }
    return digest
  }

  static func write(_ data: Data, _ url: URL, mode: Int16 = 0o644) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }
}
