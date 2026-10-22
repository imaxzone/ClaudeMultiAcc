import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// The Claude update check: feed → download → verify → store, with fakes for the network and the installer.
@Suite struct ClaudeUpdateCheckerTests {
  static func release(_ version: String = "3.1623.3") -> ClaudeRelease {
    ClaudeRelease(
      version: version, url: URL(string: "https://downloads.claude.ai/releases/darwin/arm64/\(version)/Claude-b577.zip")!,
      sha256: String(repeating: "a", count: 64), size: 263_612_185)
  }

  @Test func noDownloadWhenTheFeedOffersNothingNewer() async throws {
    let r = try rig()
    let checker = await r.checker()
    #expect(await checker.checkNow(manual: true) == .upToDate(version: "3.1623.0"))
    #expect(await checker.checkNow(manual: false) == .idle)
    r.feed.answer(.success(.available(Self.release("3.1623.0"))))
    #expect(await checker.checkNow(manual: true) == .upToDate(version: "3.1623.0"))
    try ClaudeSourceStoreTests.makeClaude(r.store.slot(for: "3.1623.3").appendingPathComponent("Claude.app"), version: "3.1623.3")
    r.feed.answer(.success(.available(Self.release("3.1623.3"))))
    #expect(await checker.checkNow(manual: true) == .upToDate(version: "3.1623.3"))
    #expect(r.feed.calls.map(\.current) == ["3.1623.0", "3.1623.0", "3.1623.0", "3.1623.3"])
    #expect(r.feed.calls.allSatisfy { $0.osVersion == "26.1.0" })
    #expect(r.downloader.calls.isEmpty)
    #expect(r.updatesLog.contains("[claude-update] none newer than 3.1623.0"))
  }

  @Test func aNewReleaseIsDownloadedVerifiedStoredAndAnnounced() async throws {
    let r = try rig(download: .finish([0, 0.001, 0.25, 0.2549, 0.5, 1]))
    try FileManager.default.createDirectory(at: r.store.incomingDir, withIntermediateDirectories: true)
    try Data("left over".utf8).write(to: r.store.incomingDir.appendingPathComponent("stale.zip"))
    r.feed.answer(.success(.available(Self.release())))
    let result = await r.checker().checkNow(manual: false)
    #expect(result == .ready(version: "3.1623.3"))
    #expect(r.statuses.all == [
      .checking, .downloading(version: "3.1623.3", percent: 0), .downloading(version: "3.1623.3", percent: 25),
      .downloading(version: "3.1623.3", percent: 50), .downloading(version: "3.1623.3", percent: 100),
      .verifying(version: "3.1623.3"), .ready(version: "3.1623.3"),
    ])
    let newest = try #require(r.store.newest())
    #expect(newest.version == "3.1623.3" && !newest.isOfficial)
    #expect(r.sources.all == [newest])
    let archive = r.store.incomingDir.appendingPathComponent("Claude.zip")
    #expect(r.downloader.calls == [archive])
    #expect(r.installer.calls.map(\.archive) == [archive])
    #expect(r.installer.calls.first?.incoming == ["Claude.zip"])
    #expect(!FileManager.default.fileExists(atPath: r.store.incomingDir.path))
    #expect(r.updatesLog.contains("[claude-update] 3.1623.0 → stored 3.1623.3"))
  }

  @Test func aFailedDownloadWipesIncomingAndStoresNothing() async throws {
    let r = try rig(download: .fail(ClaudeUpdateFailure.network("connection lost")))
    r.feed.answer(.success(.available(Self.release())))
    #expect(await r.checker().checkNow(manual: true) == .failed(.network("connection lost")))
    #expect(r.downloader.calls.count == 1)
    #expect(r.installer.calls.isEmpty)
    #expect(r.slotNames.isEmpty)
    #expect(r.store.newest()?.isOfficial == true)
    #expect(r.sources.all.isEmpty)

    let bad = try rig(install: .checksumMismatch)
    bad.feed.answer(.success(.available(Self.release())))
    #expect(await bad.checker().checkNow(manual: true) == .failed(.checksumMismatch))
    #expect(bad.installer.calls.count == 1)
    #expect(bad.slotNames.isEmpty)
    #expect(bad.updatesLog.contains("[claude-update] failed: checksumMismatch (manual)"))
  }

  @Test func failuresAreShownOnlyForManualChecks() async throws {
    let r = try rig()
    r.feed.answer(.failure(ClaudeUpdateFailure.badAnswer("HTTP 500")))
    let checker = await r.checker()
    #expect(await checker.checkNow(manual: false) == .idle)
    #expect(r.statuses.all == [.checking, .idle])
    #expect(await checker.checkNow(manual: true) == .failed(.badAnswer("HTTP 500")))
    let error: any Error = URLError(.timedOut)
    r.feed.answer(.failure(error))
    #expect(await checker.checkNow(manual: true) == .failed(.network(String(describing: error))))
    #expect(await checker.status == .failed(.network(String(describing: error))))
    #expect(r.statuses.all == [
      .checking, .idle, .checking, .failed(.badAnswer("HTTP 500")), .checking, .failed(.network(String(describing: error))),
    ])
    #expect(r.updatesLog.components(separatedBy: "[claude-update] failed: ").count == 4)
  }

  @Test func notEnoughSpaceStopsBeforeDownloading() async throws {
    let r = try rig(free: 1_000)
    r.feed.answer(.success(.available(Self.release())))
    let needed = ClaudeUpdateChecker.requiredFreeBytes
    #expect(needed == 2_000_000_000)
    #expect(await r.checker().checkNow(manual: true) == .failed(.notEnoughSpace(free: 1_000, needed: needed)))
    #expect(r.space.asked == [r.paths.dataDir])
    #expect(r.downloader.calls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: r.store.incomingDir.path))
  }

  @Test func withoutTheOfficialAppNothingIsRequested() async throws {
    let r = try rig(official: nil)
    try ClaudeSourceStoreTests.makeClaude(r.store.slot(for: "3.1623.3").appendingPathComponent("Claude.app"), version: "3.1623.3")
    let checker = await r.checker()
    #expect(await checker.checkNow(manual: true) == .failed(.officialMissing))
    #expect(await checker.checkNow(manual: false) == .idle)
    #expect(r.feed.calls.isEmpty)
    #expect(r.downloader.calls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: r.paths.claudeUpdateFile.path))
    #expect(r.slotNames == ["3.1623.3.noindex"])
  }

  @Test func overlappingChecksShareOnePassAndTheManualOneSeesTheResult() async throws {
    let r = try rig()
    let hold = Hold()
    r.feed.hold(hold)
    let checker = await r.checker()
    let automatic = Task { await checker.checkNow(manual: false) }
    await hold.started.wait()
    let manual = Task { await checker.checkNow(manual: true) }
    while await !checker.passIsManual { await Task.yield() }
    await hold.release.open()
    #expect(await manual.value == .upToDate(version: "3.1623.0"))
    #expect(await automatic.value == .upToDate(version: "3.1623.0"))
    #expect(r.feed.calls.count == 1)
  }

  @Test func aCheckDuringADownloadJoinsIt() async throws {
    let hold = Hold()
    let r = try rig(download: .hold(hold, [0, 0.42]))
    r.feed.answer(.success(.available(Self.release())))
    let checker = await r.checker()
    let automatic = Task { await checker.checkNow(manual: false) }
    await hold.started.wait()
    let manual = Task { await checker.checkNow(manual: true) }
    while await !checker.passIsManual { await Task.yield() }
    await hold.release.open()
    #expect(await manual.value == .ready(version: "3.1623.3"))
    #expect(await automatic.value == .ready(version: "3.1623.3"))
    #expect(r.feed.calls.count == 1)
    #expect(r.downloader.calls.count == 1)
    #expect(r.installer.calls.count == 1)
    #expect(r.sources.all.count == 1)
    #expect(r.statuses.all.contains(.downloading(version: "3.1623.3", percent: 42)))
  }

  @Test func aDownloadNotNewerThanTheOfficialAppIsPruned() async throws {
    let r = try rig(official: "3.1623.3")
    for version in ["3.1623.1", "3.1623.3"] {
      try ClaudeSourceStoreTests.makeClaude(r.store.slot(for: version).appendingPathComponent("Claude.app"), version: version)
    }
    let checker = await r.checker()
    guard case .acquired(let held) = UpdateLock.acquire(UpdateLock.file(r.paths)) else {
      Issue.record("cannot take update.lock")
      return
    }
    #expect(await checker.checkNow(manual: true) == .upToDate(version: "3.1623.3"))
    #expect(r.slotNames == ["3.1623.1.noindex", "3.1623.3.noindex"])
    held.release()
    #expect(await checker.checkNow(manual: true) == .upToDate(version: "3.1623.3"))
    #expect(r.slotNames.isEmpty)
    #expect(r.feed.calls.map(\.current) == ["3.1623.3", "3.1623.3"])
    #expect(r.updatesLog.contains("removed superseded 3.1623.1, 3.1623.3"))
  }

  @Test func theDeviceIdIsCreatedOnceAndReused() async throws {
    let r = try rig()
    let checker = await r.checker()
    _ = await checker.checkNow(manual: false)
    _ = await checker.checkNow(manual: true)
    _ = await r.checker().checkNow(manual: true)
    let ids = r.feed.calls.map(\.deviceId)
    #expect(ids.count == 3 && Set(ids).count == 1)
    let id = try #require(ids.first)
    #expect(UUID(uuidString: id) != nil)
    let file = r.paths.claudeUpdateFile
    #expect(file == r.paths.dataDir.appendingPathComponent("claude-update.json"))
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    #expect(try Self.stored(file) == ["deviceId": id])
    for corrupt in ["not json", "{\"deviceId\":\"abc\"}"] {
      try Data(corrupt.utf8).write(to: file)
      _ = await checker.checkNow(manual: true)
      let fresh = try #require(r.feed.calls.last?.deviceId)
      #expect(fresh != id && UUID(uuidString: fresh) != nil)
      #expect(try Self.stored(file) == ["deviceId": fresh])
    }
  }

  @Test func theEnvironmentSwitchStopsOnlyAutomaticChecks() async throws {
    let r = try rig()
    let checker = await r.checker(environment: [ClaudeUpdateChecker.disableVariable: "1"])
    #expect(ClaudeUpdateChecker.disableVariable == "CMACC_NO_CLAUDE_UPDATE_CHECK")
    await checker.start()
    #expect(await !checker.isScheduled)
    #expect(r.sleeps.calls.isEmpty)
    #expect(await checker.checkNow(manual: true) == .upToDate(version: "3.1623.0"))
    #expect(r.feed.calls.count == 1)
  }

  @Test func startChecksAfterTheDelayThenEveryIntervalUntilStopped() async throws {
    let r = try rig()
    let checker = await r.checker(environment: [ClaudeUpdateChecker.disableVariable: "0"])
    await checker.start()
    await checker.start()
    await r.sleeps.parked.wait()
    #expect(r.sleeps.calls == [.seconds(60), .seconds(6 * 60 * 60)])
    #expect(r.feed.calls.count == 1)
    #expect(await checker.status == .idle)
    await checker.stop()
    #expect(await !checker.isScheduled)
  }

  @Test func stopCancelsAnInFlightDownloadAndLeavesNothing() async throws {
    let started = Latch()
    let r = try rig(download: .hang(started))
    r.feed.answer(.success(.available(Self.release())))
    let checker = await r.checker()
    let pass = Task { await checker.checkNow(manual: true) }
    await started.wait()
    await checker.stop()
    #expect(await pass.value == .idle)
    #expect(r.installer.calls.isEmpty)
    #expect(r.slotNames.isEmpty)
    #expect(r.updatesLog.contains("[claude-update] cancelled (manual)"))
  }

  /// An archive that failed verification is not downloaded again by the automatic checks (264 MB each time); ↻
  /// retries it, a network failure is not remembered, and a new archive of the same version is tried again.
  @Test func aRejectedArchiveIsNotDownloadedAgainAutomatically() async throws {
    let r = try rig(install: .notGenuine("team"))
    r.feed.answer(.success(.available(Self.release())))
    let checker = await r.checker()
    #expect(await checker.checkNow(manual: false) == .idle)
    #expect(await checker.checkNow(manual: false) == .idle)
    #expect(r.downloader.calls.count == 1)
    #expect(r.updatesLog.contains("[claude-update] 3.1623.3 skipped: its archive failed verification before"))
    #expect(try Self.stored(r.paths.claudeUpdateFile)["rejectedVersion"] == "3.1623.3")
    #expect(await checker.checkNow(manual: true) == .failed(.notGenuine("team")))
    #expect(r.downloader.calls.count == 2)
    let other = Self.release()
    r.feed.answer(.success(.available(ClaudeRelease(
      version: other.version, url: other.url, sha256: String(repeating: "b", count: 64), size: other.size))))
    #expect(await checker.checkNow(manual: false) == .idle)
    #expect(r.downloader.calls.count == 3)

    let offline = try rig(download: .fail(ClaudeUpdateFailure.network("offline")))
    offline.feed.answer(.success(.available(Self.release())))
    let again = await offline.checker()
    _ = await again.checkNow(manual: false)
    _ = await again.checkNow(manual: false)
    #expect(offline.downloader.calls.count == 2)
  }

  /// A pass that still stores its download after `stop()` (quitting) does not start a rebuild.
  @Test func aDownloadStoredAfterStopIsNotAnnounced() async throws {
    let hold = Hold()
    let r = try rig(download: .hold(hold, [0, 1]))
    r.feed.answer(.success(.available(Self.release())))
    let checker = await r.checker()
    let pass = Task { await checker.checkNow(manual: true) }
    await hold.started.wait()
    await checker.stop()
    await hold.release.open()
    _ = await pass.value
    #expect(r.sources.all.isEmpty)
  }

  static func stored(_ file: URL) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
  }
}

// MARK: - Rig

extension ClaudeUpdateCheckerTests {
  /// One temp data folder with an official Claude of `official` (none for nil) and fakes around the checker.
  struct Rig {
    let paths: Paths
    let store: ClaudeSourceStore
    let feed = FakeFeed()
    let downloader: FakeDownloader
    let installer: FakeInstaller
    let space: FakeSpace
    let sleeps = FakeSleep()
    let statuses = Recorder<ClaudeUpdateStatus>()
    let sources = Recorder<ClaudeSource>()

    /// A checker over this rig (several share the data folder and the fakes).
    func checker(environment: [String: String] = [:]) async -> ClaudeUpdateChecker {
      let space = space
      let sleeps = sleeps
      let checker = ClaudeUpdateChecker(
        paths: paths, store: store, feed: feed, downloader: downloader, installer: installer, osVersion: "26.1.0",
        freeSpace: { space.free(at: $0) }, environment: environment, sleep: { await sleeps.sleep($0) })
      let statuses = statuses
      let sources = sources
      await checker.onStatusChange { statuses.append($0) }
      await checker.onNewSource { sources.append($0) }
      return checker
    }

    var updatesLog: String {
      (try? String(contentsOf: paths.logsDir.appendingPathComponent("updates.log"), encoding: .utf8)) ?? ""
    }

    /// Everything directly in `<data>/source`.
    var slotNames: [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).sorted()
    }
  }

  func rig(
    official: String? = "3.1623.0", download: FakeDownloader.Mode = .finish([0, 1]), install: ClaudeUpdateFailure? = nil,
    free: Int64? = 10_000_000_000, _ name: String = #function
  ) throws -> Rig {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let officialApp = root.appendingPathComponent("Applications/Claude.app", isDirectory: true)
    if let official { try ClaudeSourceStoreTests.makeClaude(officialApp, version: official) }
    let store = ClaudeSourceStore(paths: paths, officialApp: officialApp)
    return Rig(
      paths: paths, store: store, downloader: FakeDownloader(mode: download),
      installer: FakeInstaller(store: store, failure: install), space: FakeSpace(free: free))
  }

  /// `started` opens when the fake begins; it then waits for `release`.
  struct Hold {
    let started = Latch()
    let release = Latch()
  }

  final class Recorder<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    var all: [Value] { values.withLock { $0 } }
    func append(_ value: Value) { values.withLock { $0.append(value) } }
  }

  /// Answers `.none` until told otherwise; records each request.
  final class FakeFeed: ClaudeFeedFetching {
    struct Call: Equatable { let current: String; let deviceId: String; let osVersion: String }
    private let state = Mutex<(answer: Result<ClaudeFeedAnswer, any Error>, hold: Hold?)>((.success(.none), nil))
    private let recorded = Recorder<Call>()
    var calls: [Call] { recorded.all }
    func answer(_ answer: Result<ClaudeFeedAnswer, any Error>) { state.withLock { $0.answer = answer } }
    func hold(_ hold: Hold) { state.withLock { $0.hold = hold } }

    func latest(current: String, deviceId: String, osVersion: String) async throws -> ClaudeFeedAnswer {
      recorded.append(Call(current: current, deviceId: deviceId, osVersion: osVersion))
      let (answer, hold) = state.withLock { ($0.answer, $0.hold) }
      if let hold {
        await hold.started.open()
        await hold.release.wait()
      }
      return try answer.get()
    }
  }

  /// Writes a tiny archive, reports `fractions`, then finishes, throws, waits at a hold or hangs until cancelled.
  final class FakeDownloader: ClaudeArchiveDownloading {
    enum Mode: Sendable {
      case finish([Double])
      case fail(any Error)
      case hold(Hold, [Double])
      case hang(Latch)
    }

    let mode: Mode
    private let recorded = Recorder<URL>()
    var calls: [URL] { recorded.all }
    init(mode: Mode) { self.mode = mode }

    func download(_ release: ClaudeRelease, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
      recorded.append(file)
      try Data("zip".utf8).write(to: file)
      switch mode {
      case .finish(let fractions):
        fractions.forEach(progress)
      case .fail(let error):
        progress(0.3)
        throw error
      case .hold(let hold, let fractions):
        fractions.forEach(progress)
        await hold.started.open()
        await hold.release.wait()
      case .hang(let started):
        await started.open()
        try await Task.sleep(for: .seconds(3600))
      }
    }
  }

  /// Stores the release as a slot app (or throws `failure`); records what `incoming` held at that moment.
  final class FakeInstaller: ClaudeSourceInstalling {
    struct Call: Sendable { let archive: URL; let incoming: [String] }
    let store: ClaudeSourceStore
    let failure: ClaudeUpdateFailure?
    private let recorded = Recorder<Call>()
    var calls: [Call] { recorded.all }
    init(store: ClaudeSourceStore, failure: ClaudeUpdateFailure?) {
      self.store = store
      self.failure = failure
    }

    func install(archive: URL, release: ClaudeRelease) async throws -> ClaudeSource {
      let incoming = (try? FileManager.default.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)) ?? []
      recorded.append(Call(archive: archive, incoming: incoming.sorted()))
      if let failure { throw failure }
      let app = store.slot(for: release.version).appendingPathComponent("Claude.app", isDirectory: true)
      try ClaudeSourceStoreTests.makeClaude(app, version: release.version)
      return ClaudeSource(app: app, version: release.version, isOfficial: false)
    }
  }

  final class FakeSpace: Sendable {
    let bytes: Int64?
    private let recorded = Recorder<URL>()
    var asked: [URL] { recorded.all }
    init(free: Int64?) { bytes = free }

    func free(at dir: URL) -> Int64? {
      recorded.append(dir)
      return bytes
    }
  }

  /// The first sleep returns at once; later ones open `parked` and wait (cancellably) for an hour.
  final class FakeSleep: Sendable {
    private let recorded = Recorder<Duration>()
    let parked = Latch()
    var calls: [Duration] { recorded.all }

    func sleep(_ duration: Duration) async {
      recorded.append(duration)
      guard recorded.all.count > 1 else { return }
      await parked.open()
      try? await Task.sleep(for: .seconds(3600))
    }
  }
}
