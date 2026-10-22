import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// Moves the item into `<root>/Trash` (so tests can see it left) and logs `trash(<name>)`; throws when `failing`.
struct EditFakeTrash: EditInstance.Trashing {
  let log: EventLog
  var bin: URL?
  var failing = false

  init(log: EventLog, bin: URL? = nil, failing: Bool = false) {
    self.log = log
    self.bin = bin
    self.failing = failing
  }

  func trash(_ item: URL) async throws {
    log.add("trash(\(item.lastPathComponent))")
    if failing { throw CocoaError(.fileWriteNoPermission) }
    guard let bin else { return }
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: item, to: bin.appendingPathComponent(item.lastPathComponent))
  }
}

/// Logs `unregister(<name>)`; throws afterwards when `failing`.
struct EditFakeUnregistrar: EditInstance.Unregistering {
  let log: EventLog
  var failing = false
  func unregister(_ app: URL) async throws {
    log.add("unregister(\(app.lastPathComponent))")
    if failing { throw BuilderError.commandFailed(tool: "lsregister", exitCode: 1, stderr: "x") }
  }
}

/// `register` that throws (after logging) for the app names in `failing`.
struct EditFailingRegistrar: AppRegistering {
  let log: EventLog
  let failing: Set<String>
  func register(_ app: URL) async throws {
    log.add("register(\(app.lastPathComponent),failing=\(failing.contains(app.lastPathComponent)))")
    if failing.contains(app.lastPathComponent) { throw BuilderError.commandFailed(tool: "lsregister", exitCode: 1, stderr: "x") }
  }

  func unregister(_ app: URL) async throws {}
}

/// A clone that runs until asked to quit, then stops after `pollsToQuit` running checks; never when `stuck`.
final class EditFakeApps: RunningChecking, AppQuitting {
  private let running: Mutex<Set<String>>
  private let countdown = Mutex<[String: Int]>([:])
  private let pollsToQuit: Int
  private let stuck: Bool
  private let log: EventLog

  init(running: Set<String>, pollsToQuit: Int = 0, stuck: Bool = false, log: EventLog) {
    self.running = Mutex(running)
    self.pollsToQuit = pollsToQuit
    self.stuck = stuck
    self.log = log
  }

  func requestQuit(bundleId: String) async -> Bool {
    log.add("quit(\(bundleId))")
    guard running.withLock({ $0.contains(bundleId) }), !stuck else { return !stuck }
    if pollsToQuit == 0 {
      running.withLock { _ = $0.remove(bundleId) }
    } else {
      countdown.withLock { $0[bundleId] = pollsToQuit }
    }
    return true
  }

  func isRunning(bundleId: String, profileDir: URL?) async -> Bool {
    let left = countdown.withLock { counts -> Int? in
      guard let left = counts[bundleId] else { return nil }
      counts[bundleId] = left > 1 ? left - 1 : nil
      return left
    }
    if let left, left <= 1 { running.withLock { _ = $0.remove(bundleId) } }
    return running.withLock { $0.contains(bundleId) }
  }
}

struct EditFakeOpener: AppOpening {
  let log: EventLog
  var failing = false
  func open(app: URL) async throws {
    log.add("open(\(app.lastPathComponent))")
    if failing { throw CocoaError(.fileNoSuchFile) }
  }
}

/// The real store, except that `upsert` throws when `failing`.
struct EditFakeStore: EditInstance.Store {
  let inner: InstanceStore
  let failing: Bool
  func load() async throws -> [Instance] { try await inner.load() }
  func upsert(_ instance: Instance) async throws -> [Instance] {
    if failing { throw CocoaError(.fileWriteOutOfSpace) }
    return try await inner.upsert(instance)
  }
}

/// Records progress stages and sleeps.
final class EditRecorder: Sendable {
  private let stages = Mutex<[EditStage]>([])
  private let sleeps = Mutex<[Duration]>([])
  func stage(_ stage: EditStage) { stages.withLock { $0.append(stage) } }
  func sleep(_ duration: Duration) { sleeps.withLock { $0.append(duration) } }
  var allStages: [EditStage] { stages.withLock { $0 } }
  var slept: Duration { sleeps.withLock { $0.reduce(.zero, +) } }
}

/// A temp `Applications` with `Claude Work.app` (marker "old"), the four-instance list and an engine around fakes.
struct EditFixture {
  static let workId = "com.imaxzone.claude.work"
  let root: URL
  let paths: Paths
  let apps: URL
  let log = EventLog()
  let recorder = EditRecorder()

  init(_ name: String = #function) throws {
    root = try makeTempDir(name)
    paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    apps = root.appendingPathComponent("Applications", isDirectory: true)
    let four = String(decoding: try fixtureData("instances-four.json"), as: UTF8.self)
      .replacingOccurrences(of: "{{ROOT}}", with: root.path)
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try Data(four.utf8).write(to: paths.instancesFile)
    try Self.makeApp(apps.appendingPathComponent("Claude Work.app"), marker: "old")
  }

  /// An installed clone: its Info.plist names it (`ClonePathPolicy` reads it), `Contents/MacOS/Claude` holds `marker`.
  static func makeApp(_ app: URL, marker: String, slug: String = "work", bundleId: String = EditFixture.workId) throws {
    let info = PolicyFixture.clonePlist(slug, id: bundleId).merging(["Marker": marker]) { $1 }
    try MiniBundle.write(try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
                         app.appendingPathComponent("Contents/Info.plist"))
    try MiniBundle.write(Data(marker.utf8), app.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
  }

  var trashBin: URL { root.appendingPathComponent("Trash", isDirectory: true) }
  var store: InstanceStore { InstanceStore(paths: paths) }

  func marker(_ appName: String) -> String? {
    (try? Data(contentsOf: apps.appendingPathComponent("\(appName)/Contents/MacOS/Claude"))).map { String(decoding: $0, as: UTF8.self) }
  }

  func work() async throws -> Instance {
    try #require(try await store.load().first { $0.slug.raw == "work" })
  }

  func stagedBuilds() throws -> [URL] {
    try StagingArea(paths: paths).builds(slug: testSlug("work"))
  }

  func engine(
    apps running: EditFakeApps? = nil, verified: Bool = true, registrar: (any AppRegistering)? = nil,
    storeFails: Bool = false, trashFails: Bool = false, openFails: Bool = false, unregisterFails: Bool = false,
    mover: FileMover = .live, builder: (any CloneBuilding)? = nil
  ) -> EditInstance {
    let apps = running ?? EditFakeApps(running: [], log: log)
    let effects = EditInstance.Effects(
      store: EditFakeStore(inner: store, failing: storeFails),
      builder: builder ?? FakeCloneBuilder(paths: paths, log: log, verified: verified),
      running: apps, quitter: apps, opener: EditFakeOpener(log: log, failing: openFails),
      registrar: registrar ?? FakeRegistrar(log: log), unregistrar: EditFakeUnregistrar(log: log, failing: unregisterFails),
      trash: EditFakeTrash(log: log, bin: trashBin, failing: trashFails),
      swapper: BundleSwap(backupDir: paths.backupDir, clock: FixedClock(now: Date(timeIntervalSince1970: 1_790_000_000)),
                          timeZone: .gmt, mover: mover),
      mover: mover)
    let recorder = self.recorder
    return EditInstance(
      paths: paths, effects: effects, officialApp: self.apps.appendingPathComponent("Claude.app"),
      sleep: { recorder.sleep($0) })
  }

  func apply(_ engine: EditInstance, name: String, badge: String, reinstall: Bool = false) async throws -> EditOutcome {
    let recorder = self.recorder
    return try await engine.apply(
      InstanceChange(slug: testSlug("work"), name: name, badge: badge, reinstall: reinstall),
      identity: .certificate(sha1: testSHA1, keychain: nil), progress: { recorder.stage($0) })
  }
}
