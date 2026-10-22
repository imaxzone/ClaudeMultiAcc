import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// An ordered record of what the removal fakes were asked to do.
final class RemovalEvents: Sendable {
  private let events = Mutex<[String]>([])
  func add(_ event: String) { events.withLock { $0.append(event) } }
  var all: [String] { events.withLock { $0 } }
}

/// A running app that quits after `pollsToQuit` running checks once asked (never when `stuck`). Logs `quit(<id>)`.
final class RemovalApps: RunningChecking, AppQuitting {
  private struct State {
    var running: Bool
    var countdown: Int?
  }

  private let state: Mutex<State>
  private let pollsToQuit: Int
  private let stuck: Bool
  private let events: RemovalEvents
  private let whileQuitting: @Sendable () -> Void

  init(running: Bool, pollsToQuit: Int = 2, stuck: Bool = false, events: RemovalEvents,
       whileQuitting: @escaping @Sendable () -> Void = {}) {
    state = Mutex(State(running: running))
    self.pollsToQuit = pollsToQuit
    self.stuck = stuck
    self.events = events
    self.whileQuitting = whileQuitting
  }

  func requestQuit(bundleId: String) async -> Bool {
    events.add("quit(\(bundleId))")
    whileQuitting()
    return state.withLock { s -> Bool in
      guard s.running else { return false }
      if !stuck { s.countdown = pollsToQuit }
      return true
    }
  }

  func isRunning(bundleId: String, profileDir: URL?) async -> Bool {
    state.withLock { s -> Bool in
      if let left = s.countdown {
        s.countdown = left > 1 ? left - 1 : nil
        if left <= 1 { s.running = false }
      }
      return s.running
    }
  }
}

/// Moves items into `<root>/Trash` (so they really leave their place) and logs `trash(<path under root>)`; throws for
/// the paths in `failing` without moving them.
struct RecordingTrasher: Trashing {
  let root: URL
  let failing: Set<String>
  let events: RemovalEvents

  func trash(_ url: URL) throws -> URL? {
    let relative = RemovalFixture.relative(url, root: root)
    events.add("trash(\(relative))")
    if failing.contains(relative) { throw CocoaError(.fileWriteNoPermission) }
    let trash = root.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let landed = trash.appendingPathComponent(url.lastPathComponent)
    try FileManager.default.moveItem(at: url, to: landed)
    return landed
  }
}

/// Logs `unregister(<path under root>)`; always fails when `failing` (a failure must never surface to the user).
struct RecordingUnregistrar: AppUnregistering {
  let root: URL
  let failing: Bool
  let events: RemovalEvents

  func unregister(_ app: URL) async throws {
    events.add("unregister(\(RemovalFixture.relative(app, root: root)))")
    if failing { throw CocoaError(.fileNoSuchFile) }
  }
}

/// `update.lock` held by someone else for the first `busyAttempts` tries (logs `lock-busy`, runs `whileBusy`), then
/// free (logs `lock` / `unlock`).
final class FakeRemovalLock: RemovalLocking {
  private let left: Mutex<Int>
  private let events: RemovalEvents
  private let whileBusy: @Sendable () -> Void

  init(busyAttempts: Int, events: RemovalEvents, whileBusy: @escaping @Sendable () -> Void = {}) {
    left = Mutex(busyAttempts)
    self.events = events
    self.whileBusy = whileBusy
  }

  func tryAcquire() -> RemovalLockAttempt {
    let busy = left.withLock { n -> Bool in
      guard n > 0 else { return false }
      n -= 1
      return true
    }
    events.add(busy ? "lock-busy" : "lock")
    if busy { whileBusy() }
    return busy ? .busy : .acquired(release: { [events] in events.add("unlock") })
  }
}

/// Every duration the remover asked to sleep; nothing really waits.
final class RemovalSleeps: Sendable {
  private let durations = Mutex<[Duration]>([])
  func record(_ duration: Duration) { durations.withLock { $0.append(duration) } }
  var total: Duration { durations.withLock { $0.reduce(.zero, +) } }
}

/// A temp home with the official app, the clone `mv2` (app, profile at the standard place, two backups, one staging
/// build and look-alike decoys of other clones), the legacy `second`, `work` and the CLI-only `alt`. `SystemApplications`
/// stands in for `/Applications` (an Xcode look-alike); `Documents` and `.ssh` hold the user's files.
struct RemovalFixture {
  struct Knobs {
    var running = false
    var stuck = false
    var trashFailing: Set<String> = []
    /// `Int.max`: always held by an update pass.
    var lockBusyAttempts = 0
    /// Runs (with the fixture root) on every busy try.
    var whileLockBusy: @Sendable (URL) -> Void = { _ in }
    /// Runs (with the fixture root) when the running app is asked to quit: after the check, before anything moves.
    var whileQuitting: @Sendable (URL) -> Void = { _ in }
    var unregisterFails = false
  }

  let root: URL
  let paths: Paths
  let store: InstanceStore
  let remover: InstanceRemover
  let events: RemovalEvents
  let sleeps: RemovalSleeps

  static let mv2App = "Applications/Claude mv2.app"
  static let mv2Profile = "Library/Application Support/ClaudeProfiles/mv2"
  static let backups = ["data/backup/Claude mv2.app.20261001-120000", "data/backup/legacy-Claude mv2.app.20260901-120000"]
  static let staging = "data/staging/mv2-20261020-101010.noindex"
  static let mv2Id = "com.imaxzone.claude.mv2"

  static func relative(_ url: URL, root: URL) -> String {
    url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
  }

  init(_ k: Knobs = Knobs(), mv2Profile: String = RemovalFixture.mv2Profile, _ name: String = #function) async throws {
    let root = try makeTempDir(name)
    self.root = root
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    self.paths = paths
    try paths.ensureDataDirs()
    let store = InstanceStore(paths: paths)
    self.store = store
    let url = { (relative: String) in root.appendingPathComponent(relative) }
    _ = try await store.loadOrSeed()
    try await store.save([
      Instance(slug: testSlug("main"), name: "Claude", kind: .official, bundleId: CloneSpec.vendorBundleId,
               appPath: url("Applications/Claude.app").path, profileDir: url("Library/Application Support/Claude").path),
      Instance(slug: testSlug("second"), name: "Claude 2nd", kind: .clone, bundleId: CloneSpec.legacySecondBundleId,
               appPath: url("Applications/Claude 2nd.app").path,
               profileDir: url("Library/Application Support/ClaudeProfiles/second").path, badge: "2nd",
               builtBy: "legacy-script"),
      Instance(slug: testSlug("mv2"), name: "Claude mv2", kind: .clone, bundleId: Self.mv2Id,
               appPath: url(Self.mv2App).path, profileDir: url(mv2Profile).path, badge: "mv2", builtBy: "cmacc"),
      Instance(slug: testSlug("work"), name: "Claude Work", kind: .clone, bundleId: "com.imaxzone.claude.work",
               appPath: url("Applications/Claude Work.app").path, profileDir: url("profiles/work").path,
               builtBy: "cmacc"),
      Instance(slug: testSlug("alt"), name: "Claude (alt CLI)", kind: .cliOnly, cliConfigDir: url("claude-alt").path),
    ])
    try Self.makeTree(root)
    let events = RemovalEvents()
    let sleeps = RemovalSleeps()
    self.events = events
    self.sleeps = sleeps
    let whileQuitting = k.whileQuitting
    let apps = RemovalApps(running: k.running, stuck: k.stuck, events: events) { whileQuitting(root) }
    let whileBusy = k.whileLockBusy
    remover = InstanceRemover(
      paths: paths, store: store, running: apps, quitter: apps,
      trasher: RecordingTrasher(root: root, failing: k.trashFailing, events: events),
      unregistrar: RecordingUnregistrar(root: root, failing: k.unregisterFails, events: events),
      sizer: DiskUsage(), lock: FakeRemovalLock(busyAttempts: k.lockBusyAttempts, events: events) { whileBusy(root) },
      log: RedactingFileLog(url: paths.logsDir.appendingPathComponent("instances.log")),
      officialApp: url("Applications/Claude.app"), systemApplications: url("SystemApplications"),
      sleep: { sleeps.record($0) })
  }

  /// Files are multiples of 4096 bytes, so their size on disk is exact.
  static func makeTree(_ root: URL) throws {
    let files: [(String, Int)] = [
      ("Applications/Claude.app/Contents/Info.plist", 4096),
      ("Applications/Claude Work.app/Contents/Info.plist", 4096),
      ("\(mv2App)/Contents/Info.plist", 4096),
      ("\(mv2App)/Contents/MacOS/Claude", 8192),
      ("\(mv2Profile)/Local State", 4096),
      ("\(mv2Profile)/Cache/data_0", 12288),
      ("Library/Application Support/Claude/config.json", 4096),
      ("\(backups[0])/Contents/Info.plist.disabled", 4096),
      ("\(backups[1])/Contents/Info.plist.disabled", 4096),
      ("\(staging)/Claude mv2.app/Contents/MacOS/Claude", 8192),
      ("data/backup/Claude mv2 work.app.20261001-120000/Contents/x", 4096),
      ("data/backup/Claude Work.app.20261001-120000/Contents/x", 4096),
      ("data/backup/Claude mv2.app.bak/Contents/x", 4096),
      ("data/staging/mv2x-20261020-101010.noindex/x", 4096),
      ("data/staging/work-20261020-101010.noindex/x", 4096),
      ("outside/big", 40960),
    ]
    let fm = FileManager.default
    for (relative, size) in files {
      let url = root.appendingPathComponent(relative)
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 7, count: size).write(to: url)
    }
    // The clone's Info.plist names it (the policy reads it); padded so its size on disk stays 4096.
    try paddedPlist(PolicyFixture.clonePlist("mv2"), size: 4096)
      .write(to: root.appendingPathComponent("\(mv2App)/Contents/Info.plist"))
    try PolicyFixture.writeApp(root.appendingPathComponent("SystemApplications/Xcode.app"),
                               ["CFBundleIdentifier": "com.apple.dt.Xcode"])
    try PolicyFixture.writeApp(root.appendingPathComponent("Applications/ClaudeMultiAcc.app"),
                               ["CFBundleIdentifier": BuildInfo.bundleId])
    try MiniBundle.write(Data("notes".utf8), root.appendingPathComponent("Documents/notes.txt"))
    try MiniBundle.write(Data("key".utf8), root.appendingPathComponent(".ssh/id_ed25519"), mode: 0o600)
    // Symlinks are neither followed by the size nor taken for backups.
    try fm.createSymbolicLink(at: root.appendingPathComponent("\(mv2App)/Contents/Big"),
                              withDestinationURL: root.appendingPathComponent("outside/big"))
    try fm.createSymbolicLink(at: root.appendingPathComponent("data/backup/Claude mv2.app.20261002-120000"),
                              withDestinationURL: root.appendingPathComponent("outside"))
  }

  /// An XML plist of exactly `size` bytes (a padding string fills it up).
  static func paddedPlist(_ info: [String: String], size: Int) throws -> Data {
    func encode(_ padding: Int) throws -> Data {
      let padded = info.merging(["Padding": String(repeating: "x", count: padding)]) { $1 }
      return try PropertyListSerialization.data(fromPropertyList: padded, format: .xml, options: 0)
    }
    let data = try encode(size - (try encode(0)).count)
    #expect(data.count == size)
    return data
  }

  func exists(_ relative: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
  }

  func slugs() async throws -> [String] {
    try await store.load().map(\.slug.raw)
  }

  func log() throws -> String {
    try String(contentsOf: paths.logsDir.appendingPathComponent("instances.log"), encoding: .utf8)
  }
}

@Suite(.russian) struct InstanceRemoverTests {
  private let allSlugs = ["main", "second", "mv2", "work", "alt"]

  @Test func targetFindsTheAppItsProfileBackupsAndStagingBuilds() async throws {
    let f = try await RemovalFixture()
    let target = try await f.remover.target(slug: "mv2")
    #expect(target.name == "Claude mv2" && target.bundleId == RemovalFixture.mv2Id)
    #expect(RemovalFixture.relative(target.app, root: f.root) == RemovalFixture.mv2App)
    #expect(target.profileDir.map { RemovalFixture.relative($0, root: f.root) } == RemovalFixture.mv2Profile)
    #expect(target.backups.map { RemovalFixture.relative($0, root: f.root) } == RemovalFixture.backups)
    #expect(target.stagingBuilds.map { RemovalFixture.relative($0, root: f.root) } == [RemovalFixture.staging])
    #expect(target.hasOldCopies && target.profileReusable)
    #expect(target.items(.appOnly).map(\.kind) == [.app, .backup, .backup, .staging])
    #expect(target.items(.everything).map(\.kind) == [.app, .backup, .backup, .staging, .profile])
  }

  @Test func sizesCountTheAppWithItsOldCopiesAndTheProfileSeparately() async throws {
    let f = try await RemovalFixture()
    let target = try await f.remover.target(slug: "mv2")
    // App 4096 + 8192 (the 40 KB symlink target is not counted), backups 2 × 4096, staging 8192.
    #expect(await f.remover.appOnlySize(of: target) == 12288 + 8192 + 8192)
    #expect(await f.remover.profileSize(of: target) == 4096 + 12288)
  }

  @Test func diskUsageOfAMissingPathOrASymlinkIsZero() async throws {
    let root = try makeTempDir()
    try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("file"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"),
                                               withDestinationURL: root.appendingPathComponent("file"))
    #expect(await DiskUsage().size(of: root.appendingPathComponent("missing")) == 0)
    #expect(await DiskUsage().size(of: root.appendingPathComponent("link")) == 0)
    #expect(await DiskUsage().size(of: root.appendingPathComponent("file")) == 8192)
    #expect(await DiskUsage().size(of: root) == 8192)
  }

  @Test(arguments: [("main", "Основной Claude удалить нельзя"),
                    ("alt", "У «Claude (alt CLI)» нет приложения — удалять нечего"),
                    ("ghost", "Приложения «ghost» уже нет в списке")])
  func refusesTheOfficialAppCliOnlyAccountsAndUnknownSlugs(slug: String, message: String) async throws {
    let f = try await RemovalFixture()
    await #expect(throws: RemovalError.self) { try await f.remover.target(slug: slug) }
    let report = await f.remover.remove(slug: slug, mode: .everything)
    #expect(report.problems == [message] && report.trashed.isEmpty && !report.recordRemoved && report.changedNothing)
    #expect(f.events.all.isEmpty)
    #expect(try await f.slugs() == allSlugs)
  }

  @Test func refusesAProfileSharedWithTheOfficialApp() async throws {
    let f = try await RemovalFixture(mv2Profile: "Library/Application Support/Claude")
    await #expect(throws: RemovalError.self) { try await f.remover.target(slug: "mv2") }
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(report.changedNothing && report.problems.count == 1)
    #expect(report.problems[0] == "«Claude mv2»: папка профиля ~/Library/Application Support/Claude лежит не там, "
      + "где ClaudeMultiAcc хранит профили, — ничего не изменено")
    #expect(f.events.all.isEmpty && f.exists("Library/Application Support/Claude/config.json"))
  }

  /// The profiles root, the tool's data, the CLI's folders, the home itself and another clone's or account's folder.
  @Test(arguments: ["Library/Application Support/ClaudeProfiles", "data", "data/backup/p", "logs/p", ".claude",
                    ".claude/projects", ".claude-accounts/a", "", "profiles/work", "claude-alt"])
  func refusesAProfileThatHoldsOrSharesProtectedFolders(profile: String) async throws {
    let f = try await RemovalFixture(mv2Profile: profile)
    await #expect(throws: RemovalError.self) { try await f.remover.target(slug: "mv2") }
    #expect(await f.remover.remove(slug: "mv2", mode: .everything).changedNothing)
  }

  @Test func theLegacyCloneProfileIsNotFoundAgainByName() async throws {
    let f = try await RemovalFixture()
    let target = try await f.remover.target(slug: "second")
    #expect(!target.profileReusable && !target.hasOldCopies)
  }
}

extension RemovalEvents {
  func contains(_ event: String) -> Bool { all.contains(event) }
}

@Suite(.russian) struct InstanceRemoverLiveTests {
  @Test func updateLockGateIsBusyWhileAnotherPassHoldsTheLock() throws {
    let root = try makeTempDir()
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    guard case .acquired(let held) = UpdateLock.acquire(UpdateLock.file(paths)) else {
      Issue.record("cannot take update.lock")
      return
    }
    let gate = UpdateLockGate(paths: paths)
    guard case .busy = gate.tryAcquire() else {
      Issue.record("the gate must see the held lock")
      return
    }
    held.release()
    guard case .acquired(let release) = gate.tryAcquire() else {
      Issue.record("the gate must take a free lock")
      return
    }
    release()
  }

  @Test func unregistrarRunsLsregisterMinusU() async throws {
    let runner = ScriptedRunner()
    try await LaunchServicesUnregistrar(runner: runner).unregister(URL(fileURLWithPath: "/Applications/Claude mv2.app"))
    #expect(runner.commandLines == [["lsregister", "-u", "/Applications/Claude mv2.app"]])
    let failing = ScriptedRunner { _ in .fail(1, stderr: "nope") }
    await #expect(throws: BuilderError.self) {
      try await LaunchServicesUnregistrar(runner: failing).unregister(URL(fileURLWithPath: "/Applications/X.app"))
    }
  }
}
