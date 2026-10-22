import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Every pass builds from the newest Claude (`ClaudeSourceStore.newest()`): the official app, or a download that is
/// strictly newer. Without the official app there is no source and the pass behaves as before downloads existed.
@Suite(.serialized) struct UpdateWatcherSourceTests {
  /// A download newer than the official app (and than every clone) is built for each clone: the closed one is swapped,
  /// the open one waits as a pending build of the download's version and is swapped once it is closed.
  @Test func aDownloadedNewerSourceRebuildsClosedClonesAndLeavesOpenOnesPending() async throws {
    var k = WatcherKnobs()
    k.cloneVersion = "3.1623.0"
    let f = try await makeWatcherFixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    try writeWatcherApp(f.officialApp, version: "3.1623.0", marker: "official")
    let download = try writeDownloadedSource(f.paths, version: "3.1623.3")
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "swap home"], "\(decisions.map(\.line))")
    #expect(decisions[2].line.hasPrefix("swap home: 3.1623.0 → 3.1623.3 (backup "))
    #expect(decisions[1].detail.contains("3.1623.0 → 3.1623.3 staged at"))
    #expect(f.sources.all == [download.path, download.path])
    #expect(f.marker("Claude Home") == "new" && f.marker("Claude Work") == "old")
    let staged = try #require(try await f.pending("work"))

    let waiting = await f.watcher.handleOfficialChange()
    #expect(decisionLines(waiting).prefix(2) == ["skip second", "pending-waiting work"], "\(waiting.map(\.line))")
    #expect(try await f.pending("work") == staged && f.sources.all.count == 2)

    f.running.set([])
    let closed = await f.watcher.handleOfficialChange()
    #expect(decisionLines(closed).prefix(2) == ["skip second", "swap work"], "\(closed.map(\.line))")
    #expect(f.marker("Claude Work") == "new" && f.sources.all.count == 2)
    #expect(try await f.pending("work") == nil)
  }

  /// A download equal to or older than the official app is no source: the pass builds from the official app.
  @Test(arguments: ["2.0.0", "1.9.0"])
  func aDownloadNotNewerThanOfficialIsIgnored(version: String) async throws {
    let f = try await makeWatcherFixture(WatcherKnobs(), "not-newer-\(version)")
    defer { try? FileManager.default.removeItem(at: f.root) }
    try writeDownloadedSource(f.paths, version: version)
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisionLines(decisions) == ["skip second", "pending work", "swap home"], "\(decisions.map(\.line))")
    #expect(decisions[2].line.hasPrefix("swap home: 1.0.0 → 2.0.0 (backup "))
    #expect(f.sources.all == [f.officialApp.path, f.officialApp.path])
  }

  /// «Not newer» is measured against the newest source and says so.
  @Test func aCloneAtTheDownloadedVersionIsNotNewer() async throws {
    var k = WatcherKnobs()
    k.cloneVersion = "2.1.0"
    let f = try await makeWatcherFixture(k)
    defer { try? FileManager.default.removeItem(at: f.root) }
    try writeDownloadedSource(f.paths, version: "2.1.0")
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisions.map(\.line) == [
      "skip second: builtBy=legacy-script", "skip work: not newer (clone 2.1.0, source 2.1.0)",
      "skip home: not newer (clone 2.1.0, source 2.1.0)",
    ])
    #expect(f.sources.all.isEmpty)
  }

  /// ShipIt replacing the official app only holds back builds from it. While the official app is gone (ShipIt
  /// mid-replace, or never installed) there is no source at all: wait for ShipIt, otherwise skip as before.
  @Test func vendorShipItBlocksOnlyWhenBuildingFromTheOfficialApp() async throws {
    var k = WatcherKnobs()
    k.vendor = .installing
    let fromDownload = try await makeWatcherFixture(k, "shipit-download")
    defer { try? FileManager.default.removeItem(at: fromDownload.root) }
    let download = try writeDownloadedSource(fromDownload.paths, version: "2.1.0")
    let built = await fromDownload.watcher.handleOfficialChange()
    #expect(decisionLines(built) == ["skip second", "pending work", "swap home"], "\(built.map(\.line))")
    #expect(fromDownload.sources.all == [download.path, download.path])

    let fromOfficial = try await makeWatcherFixture(k, "shipit-official")
    defer { try? FileManager.default.removeItem(at: fromOfficial.root) }
    #expect(decisionLines(await fromOfficial.watcher.handleOfficialChange()) == ["skip second", "retry work", "retry home"])

    let midReplace = try await makeWatcherFixture(k, "shipit-missing")
    defer { try? FileManager.default.removeItem(at: midReplace.root) }
    try FileManager.default.removeItem(at: midReplace.officialApp)
    try writeDownloadedSource(midReplace.paths, version: "2.1.0")
    #expect(decisionLines(await midReplace.watcher.handleOfficialChange()) == ["skip second", "retry work", "retry home"])
    #expect(fromOfficial.sources.all.isEmpty && midReplace.sources.all.isEmpty)
  }

  /// Without the official app a download is never built from (`newest()` is nil): skipped as before downloads existed.
  @Test func withoutTheOfficialAppADownloadIsNotBuilt() async throws {
    let f = try await makeWatcherFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    try FileManager.default.removeItem(at: f.officialApp)
    try writeDownloadedSource(f.paths, version: "2.1.0")
    let decisions = await f.watcher.handleOfficialChange()
    #expect(decisions.map(\.line) == [
      "skip second: builtBy=legacy-script", "skip work: version unreadable (source ?)",
      "skip home: version unreadable (source ?)",
    ])
    #expect(f.sources.all.isEmpty && f.log.all.isEmpty)
  }
}
