import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// An update pass swaps only the clone's own app (`ClonePathPolicy`): checked before the build and again, with its
/// device and inode, right before the rename.
@Suite(.serialized) struct UpdateDeciderPolicyTests {
  private func repoint(_ f: WatcherFixture, _ slug: String, appPath: String? = nil, bundleId: String? = nil,
                       builtBy: String? = nil) async throws {
    let store = InstanceStore(paths: f.paths)
    let old = try #require(try await store.load().first { $0.slug.raw == slug })
    _ = try await store.upsert(Instance(
      slug: old.slug, name: old.name, kind: old.kind, bundleId: bundleId ?? old.bundleId, appPath: appPath ?? old.appPath,
      profileDir: old.profileDir, badge: old.badge, builtBy: builtBy ?? old.builtBy, pendingBuild: old.pendingBuild))
  }

  private func backups(_ f: WatcherFixture) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path)) ?? []
  }

  @Test func anEntryPointingAtAnotherAppIsNeitherBuiltNorSwapped() async throws {
    let f = try await makeWatcherFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let xcode = f.root.appendingPathComponent("Applications/Xcode.app")
    try writeWatcherApp(xcode, version: "1.0.0", marker: "xcode")
    try await repoint(f, "home", appPath: xcode.path)
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "fail home"])
    #expect(decisions.last?.detail.hasPrefix("foreign-bundle") == true, "\(decisions.map(\.line))")
    #expect(f.marker("Xcode") == "xcode" && f.builds == ["build(stagingOnly,certificate,work)"])
    #expect(backups(f).isEmpty)
  }

  @Test func aForeignBundleIdIsRefused() async throws {
    let f = try await makeWatcherFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await repoint(f, "home", bundleId: "com.apple.dt.Xcode")
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "fail home"])
    #expect(decisions.last?.detail.hasPrefix("bundle-id") == true)
    #expect(f.marker("Claude Home") == "old" && backups(f).isEmpty)
  }

  /// The app is replaced while its build runs: the swap checks again and leaves the impostor alone.
  @Test func anAppReplacedDuringTheBuildIsNotSwapped() async throws {
    var k = WatcherKnobs()
    let gate = BuildGate()
    k.buildGate = gate
    let f = try await makeWatcherFixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    try await repoint(f, "work", builtBy: "legacy-script")
    let watcher = f.watcher
    let pass = Task { await watcher.handleOfficialChange() }
    await gate.started.wait()
    let home = f.root.appendingPathComponent("Applications/Claude Home.app")
    try FileManager.default.moveItem(at: home, to: f.root.appendingPathComponent("real-home.app"))
    try writeWatcherApp(home, version: "1.0.0", marker: "impostor")
    await gate.release.open()
    let decisions = await pass.value
    #expect(decisionLines(decisions) == ["skip second", "skip work", "fail home"])
    #expect(f.marker("Claude Home") == "impostor" && backups(f).isEmpty)
  }
}
