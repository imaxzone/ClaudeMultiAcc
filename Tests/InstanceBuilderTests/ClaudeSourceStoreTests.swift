import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// The choice between the official Claude and the versions ClaudeMultiAcc downloaded, and the pruning of old ones.
@Suite struct ClaudeSourceStoreTests {
  struct Fixture {
    let paths: Paths
    let official: URL
    var store: ClaudeSourceStore { ClaudeSourceStore(paths: paths, officialApp: official) }
  }

  func fixture(_ name: String = #function) throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    return Fixture(paths: paths, official: root.appendingPathComponent("Applications/Claude.app", isDirectory: true))
  }

  /// A bundle with just an Info.plist.
  @discardableResult
  static func makeClaude(_ app: URL, version: String, bundleId: String = CloneSpec.vendorBundleId) throws -> URL {
    let info: [String: Any] = ["CFBundleIdentifier": bundleId, "CFBundleShortVersionString": version]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
  }

  /// `<data>/source/<slot>.noindex/Claude.app` with `version` in its Info.plist.
  @discardableResult
  static func makeDownload(_ f: Fixture, slot: String, version: String? = nil, bundleId: String = CloneSpec.vendorBundleId)
    throws -> URL
  {
    let app = f.paths.claudeSourcesDir.appendingPathComponent("\(slot).noindex/Claude.app", isDirectory: true)
    return try makeClaude(app, version: version ?? slot, bundleId: bundleId)
  }

  func slotNames(_ f: Fixture) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: f.paths.claudeSourcesDir.path)) ?? []).sorted()
  }

  @Test func newestIsNilWithoutTheOfficialApp() throws {
    let f = try fixture()
    try Self.makeDownload(f, slot: "3.1623.3")
    #expect(f.store.newest() == nil)
    #expect(f.store.downloaded()?.version == "3.1623.3")
  }

  @Test func newestPrefersTheOfficialAppOnATie() throws {
    let f = try fixture()
    try Self.makeClaude(f.official, version: "3.1623.3")
    try Self.makeDownload(f, slot: "3.1623.3")
    #expect(f.store.newest() == ClaudeSource(app: f.official, version: "3.1623.3", isOfficial: true))
  }

  @Test func newestTakesAStrictlyNewerDownload() throws {
    let f = try fixture()
    try Self.makeClaude(f.official, version: "3.1623.0")
    try Self.makeDownload(f, slot: "3.1623.1")
    let app = try Self.makeDownload(f, slot: "3.1623.3")
    #expect(f.store.newest() == ClaudeSource(app: app, version: "3.1623.3", isOfficial: false))
  }

  @Test func aSlotWithAnotherVersionOrBundleIdIsIgnored() throws {
    let f = try fixture()
    try Self.makeClaude(f.official, version: "3.1623.0")
    try Self.makeDownload(f, slot: "3.1623.3", version: "3.1623.4")
    try Self.makeDownload(f, slot: "3.1623.5", bundleId: "com.example.claude")
    try FileManager.default.createDirectory(
      at: f.paths.claudeSourcesDir.appendingPathComponent("3.1623.6.noindex"), withIntermediateDirectories: true)
    #expect(f.store.downloaded() == nil)
    #expect(f.store.newest()?.isOfficial == true)
  }

  @Test func invalidVersionsAreRejected() {
    for bad in ["../x", "3", "3.1.2.3.4", "3.a", "", "3..1", "1234567.1", " 3.1"] {
      #expect(!ClaudeSourceStore.isValidVersion(bad), "\(bad)")
    }
    for good in ["3.1623.3", "1.0", "10.20.30.40"] {
      #expect(ClaudeSourceStore.isValidVersion(good), "\(good)")
    }
  }

  @Test func pruneKeepsOnlyTheGivenVersionAndNeverFollowsSymlinks() throws {
    let f = try fixture()
    try Self.makeDownload(f, slot: "3.1623.1")
    try Self.makeDownload(f, slot: "3.1623.3")
    let outside = try Self.makeClaude(f.paths.home.appendingPathComponent("elsewhere/Claude.app"), version: "9.0")
    try FileManager.default.createSymbolicLink(
      at: f.paths.claudeSourcesDir.appendingPathComponent("9.0.noindex"),
      withDestinationURL: outside.deletingLastPathComponent())
    try FileManager.default.createDirectory(at: f.store.incomingDir, withIntermediateDirectories: true)
    try f.store.prune(keeping: "3.1623.3")
    #expect(slotNames(f) == ["3.1623.3.noindex", "incoming.noindex"])
    #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Contents/Info.plist").path))
  }

  @Test func pruneSupersededRemovesDownloadsNotNewerThanOfficial() throws {
    let f = try fixture()
    try Self.makeClaude(f.official, version: "3.1623.3")
    try Self.makeDownload(f, slot: "3.1623.1")
    try Self.makeDownload(f, slot: "3.1623.3")
    try Self.makeDownload(f, slot: "3.1700.0")
    try f.store.pruneSuperseded()
    #expect(slotNames(f) == ["3.1700.0.noindex"])
  }

  @Test func pruneSupersededKeepsEverythingWithoutTheOfficialApp() throws {
    let f = try fixture()
    try Self.makeDownload(f, slot: "3.1623.1")
    #expect(try f.store.pruneSuperseded().isEmpty)
    #expect(slotNames(f) == ["3.1623.1.noindex"])
  }
}
