import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// What an UpdateWatcher fixture varies; `buildGate` holds every build until the test opens it.
struct WatcherKnobs {
  var running: Set<String> = ["com.imaxzone.claude.work"]
  var autoRebuild = true
  var vendor: VendorUpdateState = .idle
  var identity = true
  var verified = true
  var cloneVersion = "1.0.0"
  var buildGate: BuildGate?
  /// `lsregister -u` fails (a stale LaunchServices record must never fail the swap).
  var unregisterFails = false
}

struct WatcherFixture {
  let root: URL
  let paths: Paths
  let watcher: UpdateWatcher
  let log: EventLog
  let running: MutableRunningSet
  let sleeps: SleepRecorder
  /// The `source` of every build, in order.
  let sources: EventLog
}

/// instances-four.json plus a fifth, idle cmacc-built clone `home`: main, second (legacy), work (cmacc,
/// running), alt, home (cmacc, idle). The watcher's sleep is recorded, never real.
func makeWatcherFixture(_ k: WatcherKnobs = WatcherKnobs(), _ name: String = #function) async throws -> WatcherFixture {
  let root = try makeTempDir(name)
  let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
  try paths.ensureDataDirs()
  let four = String(decoding: try fixtureData("instances-four.json"), as: UTF8.self)
    .replacingOccurrences(of: "{{ROOT}}", with: root.path)
  try Data(four.utf8).write(to: paths.instancesFile)
  let store = InstanceStore(paths: paths)
  _ = try await store.upsert(Instance(
    slug: testSlug("home"), name: "Claude Home", kind: .clone, bundleId: "com.imaxzone.claude.home",
    appPath: root.appendingPathComponent("Applications/Claude Home.app").path,
    profileDir: root.appendingPathComponent("profiles/home").path, badge: "H", builtBy: "cmacc"))
  let apps = root.appendingPathComponent("Applications")
  try writeWatcherApp(apps.appendingPathComponent("Claude.app"), version: "2.0.0", marker: "official")
  let clones = [
    ("Claude 2nd", "second", CloneSpec.legacySecondBundleId), ("Claude Work", "work", "com.imaxzone.claude.work"),
    ("Claude Home", "home", "com.imaxzone.claude.home"),
  ]
  for (name, slug, bundleId) in clones {
    try writeWatcherApp(apps.appendingPathComponent("\(name).app"), version: k.cloneVersion, marker: "old",
                        clone: (slug, bundleId))
  }
  if !k.autoRebuild { try Data("{\"updates\":{\"autoRebuild\":false}}".utf8).write(to: paths.settingsFile) }
  let log = EventLog()
  let running = MutableRunningSet(k.running)
  let sleeps = SleepRecorder()
  let identity: SigningIdentity? = k.identity ? .certificate(sha1: testSHA1, keychain: nil) : nil
  let builder = FakeCloneBuilder(paths: paths, log: log, verified: k.verified)
  let sources = EventLog()
  let gated: any CloneBuilding = k.buildGate.map { GatedCloneBuilder(inner: builder, gate: $0) } ?? builder
  let watcher = UpdateWatcher(
    paths: paths, store: store, pipeline: SourceRecordingBuilder(inner: gated, sources: sources),
    running: running, vendorShipIt: FakeVendorUpdateCheck(state: k.vendor),
    registrar: FakeRegistrar(log: log, unregisterFails: k.unregisterFails),
    log: RedactingFileLog(url: paths.logsDir.appendingPathComponent("updates.log")),
    clock: FixedClock(now: Date(timeIntervalSince1970: 1_790_000_000)), identity: { identity },
    officialApp: apps.appendingPathComponent("Claude.app"), timeZone: .gmt, sleep: { await sleeps.sleep($0) })
  return WatcherFixture(
    root: root, paths: paths, watcher: watcher, log: log, running: running, sleeps: sleeps, sources: sources)
}

/// A verified-looking download ClaudeMultiAcc stored: `<data>/source/<version>.noindex/Claude.app` with the vendor
/// bundle id and `version` (just an Info.plist).
@discardableResult
func writeDownloadedSource(_ paths: Paths, version: String) throws -> URL {
  let app = paths.claudeSourcesDir.appendingPathComponent("\(version).noindex/Claude.app", isDirectory: true)
  return try ClaudeSourceStoreTests.makeClaude(app, version: version)
}

/// `clone` adds the bundle id and `ClaudeMultiAccSlug` a real clone carries (the swap checks them).
func writeWatcherApp(_ app: URL, version: String, marker: String, clone: (slug: String, bundleId: String)? = nil) throws {
  let identity = clone.map { PolicyFixture.clonePlist($0.slug, id: $0.bundleId) } ?? [:]
  let info = try PropertyListSerialization.data(
    fromPropertyList: identity.merging(["CFBundleShortVersionString": version]) { $1 }, format: .xml, options: 0)
  try MiniBundle.write(info, app.appendingPathComponent("Contents/Info.plist"))
  try MiniBundle.write(Data(marker.utf8), app.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
}

/// The marker written into `<root>/Applications/<app>.app/Contents/MacOS/Claude` ("old", "new", or "?").
func appMarker(_ app: String, _ root: URL) -> String {
  let url = root.appendingPathComponent("Applications/\(app).app/Contents/MacOS/Claude")
  return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
}

/// `<action> <slug>` per decision.
func decisionLines(_ decisions: [UpdateDecision]) -> [String] {
  decisions.map { "\($0.action.rawValue) \($0.slug)" }
}

extension WatcherFixture {
  func marker(_ app: String) -> String { appMarker(app, root) }

  /// The fixture's official app (`<root>/Applications/Claude.app`, version 2.0.0).
  var officialApp: URL { root.appendingPathComponent("Applications/Claude.app", isDirectory: true) }

  var builds: [String] { log.all.filter { $0.hasPrefix("build") } }

  func pending(_ slug: String) async throws -> String? {
    try await InstanceStore(paths: paths).load().first { $0.slug.raw == slug }?.pendingBuild
  }

  /// `updates.log` as written so far ("" before the first line).
  var updatesLog: String {
    (try? String(contentsOf: paths.logsDir.appendingPathComponent("updates.log"), encoding: .utf8)) ?? ""
  }
}

/// Records each injected sleep instead of waiting, then runs the test's `onSleep` hook with the 1-based call number.
final class SleepRecorder: Sendable {
  private let calls = Mutex<[Duration]>([])
  private let hook = Mutex<(@Sendable (Int) async -> Void)?>(nil)

  var all: [Duration] { calls.withLock { $0 } }

  func onSleep(_ body: @escaping @Sendable (Int) async -> Void) { hook.withLock { $0 = body } }

  func sleep(_ duration: Duration) async {
    let call = calls.withLock { value -> Int in value.append(duration); return value.count }
    let body = hook.withLock { $0 }
    await body?(call)
  }
}

/// A one-shot latch: `wait()` suspends until `open()`.
actor Latch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}

/// `started` opens when a build begins; the build then waits for `release`.
struct BuildGate {
  let started = Latch()
  let release = Latch()
}

/// A FakeCloneBuilder whose builds wait at `gate` (a pass held mid-build).
struct GatedCloneBuilder: CloneBuilding {
  let inner: FakeCloneBuilder
  let gate: BuildGate

  func build(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent) async throws -> BuildReport {
    await gate.started.open()
    await gate.release.wait()
    return try await inner.build(spec: spec, source: source, identity: identity, intent: intent)
  }
}

/// Records the `source` of every build, then lets `inner` build.
struct SourceRecordingBuilder: CloneBuilding {
  let inner: any CloneBuilding
  let sources: EventLog

  func build(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent) async throws -> BuildReport {
    sources.add(source.path)
    return try await inner.build(spec: spec, source: source, identity: identity, intent: intent)
  }
}
