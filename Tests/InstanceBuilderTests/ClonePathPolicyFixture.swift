import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// A temp home for `ClonePathPolicy`: `SystemApplications` stands in for `/Applications` (the official Claude and an
/// Xcode look-alike), `Applications` is `~/Applications` (the clone `mv2` and ClaudeMultiAcc), plus the standard
/// profile of `mv2`, `~/Documents` and `~/.ssh`. Nothing outside the temp dir is read or written.
struct PolicyFixture {
  let root: URL
  let policy: ClonePathPolicy

  var system: URL { root.appendingPathComponent("SystemApplications", isDirectory: true) }
  var userApps: URL { root.appendingPathComponent("Applications", isDirectory: true) }
  var profiles: URL { root.appendingPathComponent("Library/Application Support/ClaudeProfiles", isDirectory: true) }
  var official: URL { system.appendingPathComponent("Claude.app", isDirectory: true) }

  init(_ name: String = #function) throws {
    root = try makeTempDir(name)
    let system = root.appendingPathComponent("SystemApplications", isDirectory: true)
    policy = ClonePathPolicy(
      home: root, officialApp: system.appendingPathComponent("Claude.app", isDirectory: true),
      systemApplications: system)
    try Self.writeApp(official, ["CFBundleIdentifier": CloneSpec.vendorBundleId])
    try Self.writeApp(system.appendingPathComponent("Xcode.app"), ["CFBundleIdentifier": "com.apple.dt.Xcode"])
    try Self.writeApp(userApps.appendingPathComponent("Claude mv2.app"), Self.clonePlist("mv2"))
    try Self.writeApp(userApps.appendingPathComponent("ClaudeMultiAcc.app"), ["CFBundleIdentifier": BuildInfo.bundleId])
    try MiniBundle.write(Data("state".utf8), profiles.appendingPathComponent("mv2/Local State"))
    try MiniBundle.write(Data("notes".utf8), root.appendingPathComponent("Documents/notes.txt"))
    try MiniBundle.write(Data("key".utf8), root.appendingPathComponent(".ssh/id_ed25519"), mode: 0o600)
  }

  static func writeApp(_ app: URL, _ info: [String: String]) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try MiniBundle.write(data, app.appendingPathComponent("Contents/Info.plist"))
  }

  /// What `PlistPatcher` writes into a clone: its bundle id and `ClaudeMultiAccSlug`.
  static func clonePlist(_ slug: String, id: String? = nil) -> [String: String] {
    ["CFBundleIdentifier": id ?? "com.imaxzone.claude.\(slug)", PlistPatcher.slugKey: slug]
  }

  /// A clone entry; `app` and `profile` are relative to the temp home (default: the standard places of `slug`).
  func clone(
    _ slug: String = "mv2", app: String? = nil, profile: String? = nil, bundleId: String? = nil,
    builtBy: String? = "cmacc"
  ) -> Instance {
    Instance(
      slug: testSlug(slug), name: "Claude \(slug)", kind: .clone, bundleId: bundleId ?? "com.imaxzone.claude.\(slug)",
      appPath: app.map { root.appendingPathComponent($0).path } ?? userApps.appendingPathComponent("Claude \(slug).app").path,
      profileDir: profile.map { root.appendingPathComponent($0).path } ?? profiles.appendingPathComponent(slug).path,
      builtBy: builtBy)
  }

  /// The refusal `body` throws, or nil when it passes.
  func refusal(_ body: () throws -> Any?) -> ClonePathRefusal? {
    do {
      _ = try body()
      return nil
    } catch let refusal as ClonePathRefusal {
      return refusal
    } catch {
      Issue.record("unexpected error \(error)")
      return nil
    }
  }

  func exists(_ relative: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
  }
}
