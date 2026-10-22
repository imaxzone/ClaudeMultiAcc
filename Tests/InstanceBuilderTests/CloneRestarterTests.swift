import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

private let workId = "com.imaxzone.claude.work"
private let homeId = "com.imaxzone.claude.home"

/// Running apps that quit when asked: after `pollsToQuit` running checks (0 = at once), never when in `stuck`.
/// Logs `quit(<bundle id>)`.
final class FakeApps: RunningChecking, AppQuitting {
  private struct State {
    var running: Set<String>
    var countdown: [String: Int] = [:]
  }

  private let state: Mutex<State>
  private let pollsToQuit: Int
  private let stuck: Set<String>
  private let log: EventLog

  init(running: Set<String>, pollsToQuit: Int, stuck: Set<String>, log: EventLog) {
    self.state = Mutex(State(running: running))
    self.pollsToQuit = pollsToQuit
    self.stuck = stuck
    self.log = log
  }

  var runningNow: Set<String> { state.withLock { $0.running } }

  func requestQuit(bundleId: String) async -> Bool {
    log.add("quit(\(bundleId))")
    return state.withLock { s -> Bool in
      guard s.running.contains(bundleId) else { return false }
      if stuck.contains(bundleId) { return true }
      if pollsToQuit == 0 { s.running.remove(bundleId) } else { s.countdown[bundleId] = pollsToQuit }
      return true
    }
  }

  func isRunning(bundleId: String, profileDir: URL?) async -> Bool {
    state.withLock { s -> Bool in
      if let left = s.countdown[bundleId] {
        s.countdown[bundleId] = left > 1 ? left - 1 : nil
        if left <= 1 { s.running.remove(bundleId) }
      }
      return s.running.contains(bundleId)
    }
  }
}

/// Logs `open(<app name>)`; throws for the app names in `failing`.
struct FakeOpener: AppOpening {
  let log: EventLog
  let failing: Set<String>

  func open(app: URL) async throws {
    log.add("open(\(app.lastPathComponent))")
    if failing.contains(app.lastPathComponent) { throw CocoaError(.fileNoSuchFile) }
  }
}

/// Logs `apply(running=<ids still running>)` and answers with canned decisions.
struct FakeApplier: PendingApplying {
  let log: EventLog
  let apps: FakeApps
  let respond: @Sendable () async -> [UpdateDecision]

  func applyPendingNow(manual: Bool) async -> [UpdateDecision] {
    log.add("apply(running=\(apps.runningNow.sorted().joined(separator: ",")))")
    return await respond()
  }
}

/// Every duration the restarter asked to sleep; nothing really waits.
final class RestartSleepRecorder: Sendable {
  private let durations = Mutex<[Duration]>([])
  func record(_ duration: Duration) { durations.withLock { $0.append(duration) } }
  var all: [Duration] { durations.withLock { $0 } }
  var total: Duration { all.reduce(.zero, +) }
}

@Suite(.russian) struct CloneRestarterTests {
  typealias Respond = @Sendable (InstanceStore) async -> [UpdateDecision]

  struct Knobs {
    var running: Set<String> = [workId, homeId]
    var pollsToQuit = 2
    var stuck: Set<String> = []
    var openFailures: Set<String> = []
    var respond: Respond = { _ in
      [
        UpdateDecision(slug: "second", action: .skip, detail: "builtBy=legacy-script"),
        UpdateDecision(slug: "work", action: .swap, detail: "1.0.0 → 2.0.0 from pending build"),
        UpdateDecision(slug: "home", action: .swap, detail: "1.0.0 → 2.0.0 from pending build"),
      ]
    }
  }

  struct Fixture {
    let paths: Paths
    let store: InstanceStore
    let restarter: CloneRestarter
    let log: EventLog
    let sleeps: RestartSleepRecorder
  }

  /// instances-four.json with pending builds on `second` (legacy) and `work`, plus `home` (cmacc, pending),
  /// `spare` (cmacc, nothing pending) and `broken` (cmacc, pending, no app path).
  private func fixture(_ k: Knobs = Knobs(), _ name: String = #function) async throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    try paths.ensureDataDirs()
    let four = String(decoding: try fixtureData("instances-four.json"), as: UTF8.self)
      .replacingOccurrences(of: "{{ROOT}}", with: root.path)
    try Data(four.utf8).write(to: paths.instancesFile)
    let store = InstanceStore(paths: paths)
    let staged = { (slug: String) in root.appendingPathComponent("data/staging/\(slug)/Claude.app").path }
    for instance in try await store.load() where ["second", "work"].contains(instance.slug.raw) {
      _ = try await store.upsert(instance.withBuild(builtBy: instance.builtBy, pendingBuild: staged(instance.slug.raw)))
    }
    for (slug, pending, app) in [("home", true, true), ("spare", false, true), ("broken", true, false)] {
      _ = try await store.upsert(Instance(
        slug: testSlug(slug), name: "Claude \(slug.capitalized)", kind: .clone, bundleId: "com.imaxzone.claude.\(slug)",
        appPath: app ? root.appendingPathComponent("Applications/Claude \(slug.capitalized).app").path : nil,
        profileDir: root.appendingPathComponent("profiles/\(slug)").path, badge: "X", builtBy: "cmacc",
        pendingBuild: pending ? staged(slug) : nil))
    }
    let log = EventLog()
    let sleeps = RestartSleepRecorder()
    let apps = FakeApps(running: k.running, pollsToQuit: k.pollsToQuit, stuck: k.stuck, log: log)
    let respond = k.respond
    let restarter = CloneRestarter(
      store: store, running: apps, quitter: apps, opener: FakeOpener(log: log, failing: k.openFailures),
      applier: FakeApplier(log: log, apps: apps, respond: { await respond(store) }),
      log: RedactingFileLog(url: paths.logsDir.appendingPathComponent("updates.log")), sleep: { sleeps.record($0) })
    return Fixture(paths: paths, store: store, restarter: restarter, log: log, sleeps: sleeps)
  }

  private func updatesLog(_ f: Fixture) throws -> String {
    try String(contentsOf: f.paths.logsDir.appendingPathComponent("updates.log"), encoding: .utf8)
  }

  @Test func twoRunningClonesQuitInstallAndReopenInListOrder() async throws {
    let f = try await fixture()
    let report = await f.restarter.restart(slugs: ["home", "work"])
    #expect(report == CloneRestartReport(updated: ["Claude Work", "Claude Home"], problems: []))
    #expect(f.log.all == [
      "quit(\(workId))", "quit(\(homeId))", "apply(running=)", "open(Claude Work.app)", "open(Claude Home.app)",
    ])
    #expect(!f.sleeps.all.isEmpty && f.sleeps.all.allSatisfy { $0 == CloneRestarter.pollInterval })
    let text = try updatesLog(f)
    #expect(text.contains("[updates] restart work: quit requested") && text.contains("[updates] restart home: quit requested"))
    #expect(text.contains("restart work: reopened") && text.contains("restart home: reopened"))
  }

  @Test func anIdlePendingCloneIsInstalledWithoutQuitOrReopen() async throws {
    var k = Knobs()
    k.running = []
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work"])
    #expect(report == CloneRestartReport(updated: ["Claude Work"], problems: []))
    #expect(f.log.all == ["apply(running=)"])
    #expect(f.sleeps.all.isEmpty)
    #expect(try updatesLog(f).contains("restart work: not running"))
  }

  @Test func aCloneThatDoesNotQuitIsNotReopenedWhileTheOtherUpdates() async throws {
    var k = Knobs()
    k.stuck = [homeId]
    k.respond = { _ in
      [
        UpdateDecision(slug: "work", action: .swap, detail: "1.0.0 → 2.0.0 from pending build"),
        UpdateDecision(slug: "home", action: .pendingWaiting, detail: "running; 2.0.0 build waits"),
      ]
    }
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work", "home"])
    #expect(report == CloneRestartReport(
      updated: ["Claude Work"], problems: ["«Claude Home» не закрылся — новая версия встанет после его закрытия"]))
    #expect(f.log.all == ["quit(\(workId))", "quit(\(homeId))", "apply(running=\(homeId))", "open(Claude Work.app)"])
    #expect(f.sleeps.total == CloneRestarter.quitTimeout)
    #expect(try updatesLog(f).contains("restart home: did not quit in 30 s"))
  }

  @Test func noPassRunsWhenNoTargetQuits() async throws {
    var k = Knobs()
    k.stuck = [workId, homeId]
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work", "home"])
    #expect(report.updated.isEmpty)
    #expect(report.problems == [
      "«Claude Work» не закрылся — новая версия встанет после его закрытия",
      "«Claude Home» не закрылся — новая версия встанет после его закрытия",
    ])
    #expect(f.log.all == ["quit(\(workId))", "quit(\(homeId))"])
    #expect(f.sleeps.total == CloneRestarter.quitTimeout)
  }

  /// Official, legacy, CLI-only, nothing-pending and incomplete instances are never quit, installed or opened.
  @Test func onlyCmaccClonesWithAPendingBuildAreTargets() async throws {
    var k = Knobs()
    k.running = [workId, homeId, CloneSpec.vendorBundleId, CloneSpec.legacySecondBundleId, "com.imaxzone.claude.spare",
                 "com.imaxzone.claude.broken"]
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["main", "second", "alt", "spare", "broken", "work"])
    #expect(report == CloneRestartReport(updated: ["Claude Work"], problems: []))
    #expect(f.log.all.filter { !$0.hasPrefix("apply") } == ["quit(\(workId))", "open(Claude Work.app)"])
    #expect(f.log.all.filter { $0.hasPrefix("apply") }.count == 1)
  }

  @Test func noTargetsMeansNoPassAndAnEmptyReport() async throws {
    let f = try await fixture()
    let report = await f.restarter.restart(slugs: ["main", "second", "alt", "spare", "broken", "nope"])
    #expect(report == CloneRestartReport(updated: [], problems: []))
    #expect(f.log.all.isEmpty && f.sleeps.all.isEmpty)
  }

  @Test func aFailedSwapStillReopensTheClone() async throws {
    var k = Knobs()
    k.respond = { _ in [UpdateDecision(slug: "work", action: .fail, detail: "rename failed (errno 13)\nat BundleSwapper")] }
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work"])
    #expect(report == CloneRestartReport(updated: [], problems: ["«Claude Work»: не удалось обновить — rename failed (errno 13)"]))
    #expect(f.log.all == ["quit(\(workId))", "apply(running=\(homeId))", "open(Claude Work.app)"])
  }

  @Test func aWaitingDecisionWithThePendingBuildStillSetIsReported() async throws {
    var k = Knobs()
    k.respond = { _ in [UpdateDecision(slug: "work", action: .pendingWaiting, detail: "running; build waits")] }
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work"])
    #expect(report == CloneRestartReport(updated: [], problems: ["«Claude Work»: обновление не установлено (pending-waiting)"]))
    #expect(f.log.all.last == "open(Claude Work.app)")
  }

  /// The quit-triggered watcher pass installed the build first; this pass then says "not newer".
  @Test func aCloneAlreadySwappedByAnotherPassCountsAsUpdated() async throws {
    var k = Knobs()
    k.respond = { store in
      if let work = try? await store.load().first(where: { $0.slug.raw == "work" }) {
        _ = try? await store.upsert(work.withBuild(builtBy: "cmacc", pendingBuild: nil))
      }
      return [UpdateDecision(slug: "work", action: .skip, detail: "not newer (clone 2.0.0, official 2.0.0)")]
    }
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work"])
    #expect(report == CloneRestartReport(updated: ["Claude Work"], problems: []))
    #expect(f.log.all.last == "open(Claude Work.app)")
  }

  @Test func anOpenErrorIsReported() async throws {
    var k = Knobs()
    k.openFailures = ["Claude Home.app"]
    let f = try await fixture(k)
    let report = await f.restarter.restart(slugs: ["work", "home"])
    #expect(report == CloneRestartReport(updated: ["Claude Work", "Claude Home"], problems: ["«Claude Home»: не удалось открыть снова"]))
    #expect(f.log.all.suffix(2) == ["open(Claude Work.app)", "open(Claude Home.app)"])
    #expect(try updatesLog(f).contains("restart home: reopen failed"))
  }
}
