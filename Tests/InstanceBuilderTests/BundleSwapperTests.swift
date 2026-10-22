import Foundation
import Testing
@testable import InstanceBuilder

@Suite struct BundleSwapperTests {
  static let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC
  static let utc = TimeZone(identifier: "UTC") ?? .gmt

  private func makeApp(_ url: URL, marker: String) throws {
    try MiniBundle.write(Data("<plist>\(marker)</plist>".utf8), url.appendingPathComponent("Contents/Info.plist"))
    try MiniBundle.write(Data(marker.utf8), url.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
  }

  private func marker(_ app: URL) -> String? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Claude"))).map { String(decoding: $0, as: UTF8.self) }
  }

  @Test func swapMovesLiveAsideDisablesItsPlistAndInstallsStaged() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    let staged = root.appendingPathComponent("staging/second-x.noindex/Claude 2nd.app")
    try makeApp(live, marker: "old")
    try makeApp(staged, marker: "new")
    let backup = try BundleSwapper.swap(live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
                                        now: Self.now, timeZone: Self.utc)
    #expect(backup.lastPathComponent == "Claude 2nd.app.20260921-141320")
    #expect(backup.deletingLastPathComponent().lastPathComponent == "backup")
    #expect(marker(live) == "new")
    #expect(marker(backup) == "old")
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("Contents/Info.plist").path))
    #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Contents/Info.plist.disabled").path))
  }

  @Test func missingStagedRestoresTheLiveAppAndItsPlist() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    try makeApp(live, marker: "old")
    #expect(throws: (any Error).self) {
      _ = try BundleSwapper.swap(live: live, staged: root.appendingPathComponent("nope.app"),
                                 backupDir: root.appendingPathComponent("backup"), now: Self.now, timeZone: Self.utc)
    }
    #expect(marker(live) == "old")
    #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("Contents/Info.plist").path))
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backup").path)) ?? []
    #expect(leftovers.isEmpty)
  }

  @Test func liveWithoutInfoPlistFailsMidwayAndIsRestored() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    let staged = root.appendingPathComponent("staged/Claude 2nd.app")
    try MiniBundle.write(Data("old".utf8), live.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
    try makeApp(staged, marker: "new")
    #expect(throws: (any Error).self) {
      _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
                                 now: Self.now, timeZone: Self.utc)
    }
    #expect(marker(live) == "old")
    #expect(marker(staged) == "new")
  }

  @Test func refusesAnExistingBackupTarget() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    let staged = root.appendingPathComponent("staged/Claude 2nd.app")
    try makeApp(live, marker: "old")
    try makeApp(staged, marker: "new")
    let backupDir = root.appendingPathComponent("backup")
    try FileManager.default.createDirectory(
      at: backupDir.appendingPathComponent("Claude 2nd.app.20260921-141320"), withIntermediateDirectories: true)
    #expect(throws: SwapError.backupExists(backupDir.appendingPathComponent("Claude 2nd.app.20260921-141320").path)) {
      _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: backupDir, now: Self.now, timeZone: Self.utc)
    }
    #expect(marker(live) == "old" && marker(staged) == "new")
  }

  @Test func refusesAMissingLiveApp() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let staged = root.appendingPathComponent("staged/Claude 2nd.app")
    try makeApp(staged, marker: "new")
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    #expect(throws: SwapError.liveMissing(live.path)) {
      _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
                                 now: Self.now, timeZone: Self.utc)
    }
  }

  /// TOCTOU: the app checked before the build is compared again (device and inode) right before the first rename.
  @Test func refusesALiveAppReplacedSinceItWasChecked() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    let staged = root.appendingPathComponent("staged/Claude 2nd.app")
    try makeApp(live, marker: "old")
    try makeApp(staged, marker: "new")
    let checked = try #require(FileIdentity.of(live))
    try FileManager.default.moveItem(at: live, to: root.appendingPathComponent("real.app"))
    try makeApp(live, marker: "impostor")
    #expect(throws: SwapError.liveChanged(live.path)) {
      _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
                                 now: Self.now, timeZone: Self.utc, expectedLive: checked)
    }
    #expect(marker(live) == "impostor" && marker(staged) == "new")
    #expect((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backup").path)) ?? [] == [])
    let same = try #require(FileIdentity.of(live))
    _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
                               now: Self.now, timeZone: Self.utc, expectedLive: same)
    #expect(marker(live) == "new")
  }
}
