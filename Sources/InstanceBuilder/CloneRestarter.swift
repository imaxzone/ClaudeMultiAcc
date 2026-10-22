import Foundation
import Support

/// One applying pass of the update watcher that has really run (UpdateWatcher conforms); `manual` builds even while
/// `updates.autoRebuild` is off.
public protocol PendingApplying: Sendable {
  func applyPendingNow(manual: Bool) async -> [UpdateDecision]
}

/// Asks a running app to quit politely (no force kill). Returns whether a quit request was sent to at least one process.
public protocol AppQuitting: Sendable {
  func requestQuit(bundleId: String) async -> Bool
}

/// Opens an app bundle (through its launcher, as Finder would).
public protocol AppOpening: Sendable {
  func open(app: URL) async throws
}

/// What one "Перезапустить и обновить" did, for the menu.
public struct CloneRestartReport: Sendable, Equatable {
  /// Names of clones whose waiting build was installed (decision `.swap`, or `pendingBuild` gone without a failure).
  public let updated: [String]
  /// User-facing lines (UI language) for everything that did not go as planned; empty when all is well.
  public let problems: [String]

  public init(updated: [String], problems: [String]) {
    self.updated = updated
    self.problems = problems
  }
}

/// Quits the cmacc-built clones whose verified build waits in `pendingBuild`, runs one applying pass of the watcher
/// and reopens the clones that were running. A clone that does not quit in time is left alone; its build keeps waiting.
public struct CloneRestarter: Sendable {
  static let pollInterval: Duration = .milliseconds(500)
  static let quitTimeout: Duration = .seconds(30)
  static let maxDetailLength = 120

  let store: InstanceStore
  let running: any RunningChecking
  let quitter: any AppQuitting
  let opener: any AppOpening
  let applier: any PendingApplying
  let log: RedactingFileLog
  let sleep: @Sendable (Duration) async -> Void

  public init(
    store: InstanceStore, running: any RunningChecking, quitter: any AppQuitting, opener: any AppOpening,
    applier: any PendingApplying, log: RedactingFileLog,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.store = store
    self.running = running
    self.quitter = quitter
    self.opener = opener
    self.applier = applier
    self.log = log
    self.sleep = sleep
  }

  /// A cmacc-built clone with a pending build and everything needed to quit, check and reopen it.
  struct Target: Sendable {
    let slug: String
    let name: String
    let bundleId: String
    let profileDir: URL
    let app: URL

    init?(_ instance: Instance) {
      // A crafted entry with another app's bundle id is never quit and reopened.
      guard instance.kind == .clone, instance.builtBy == "cmacc", instance.pendingBuild != nil,
            let bundleId = instance.bundleId, ClonePathPolicy.isCloneBundleId(bundleId, slug: instance.slug),
            let appPath = instance.appPath, let profileDir = instance.profileDir
      else { return nil }
      slug = instance.slug.raw
      name = instance.name
      self.bundleId = bundleId
      self.profileDir = URL(fileURLWithPath: profileDir, isDirectory: true)
      app = URL(fileURLWithPath: appPath, isDirectory: true)
    }
  }

  /// How the applying pass left one target.
  enum Verdict: Equatable {
    case updated
    case failed(String)
    case notInstalled(String)

    func problem(name: String) -> String? {
      switch self {
      case .updated: nil
      case .failed(let detail): BuilderText.format("restart.failed", name, detail)
      case .notInstalled(let action): BuilderText.format("restart.not-installed", name, action)
      }
    }
  }

  /// Closes the given clones that wait for a quit, installs their pending builds and reopens the ones that were running.
  public func restart(slugs: [String]) async -> CloneRestartReport {
    let targets: [Target]
    do {
      targets = try await store.load().filter { slugs.contains($0.slug.raw) }.compactMap(Target.init)
    } catch {
      await note("all", "cannot read instances.json: \(error)")
      return CloneRestartReport(updated: [], problems: [BuilderText.string("restart.store-unreadable")])
    }
    guard !targets.isEmpty else { return CloneRestartReport(updated: [], problems: []) }
    let wasRunning = await requestQuits(targets)
    let stuck = await waitForQuit(targets.filter { wasRunning.contains($0.slug) })
    let idle = targets.filter { !stuck.contains($0.slug) }
    let verdicts = await install(idle)
    let openFailures = await reopen(idle.filter { wasRunning.contains($0.slug) })
    let problems = targets.flatMap { target in
      [
        stuck.contains(target.slug) ? BuilderText.format("restart.stuck", target.name) : nil,
        verdicts[target.slug]?.problem(name: target.name), openFailures[target.slug],
      ].compactMap { $0 }
    }
    return CloneRestartReport(updated: targets.filter { verdicts[$0.slug] == .updated }.map(\.name), problems: problems)
  }

  /// Sends a quit request to every running target; returns the slugs that were running.
  private func requestQuits(_ targets: [Target]) async -> Set<String> {
    var wasRunning: Set<String> = []
    for target in targets {
      guard await running.isRunning(bundleId: target.bundleId, profileDir: target.profileDir) else {
        await note(target.slug, "not running")
        continue
      }
      wasRunning.insert(target.slug)
      let sent = await quitter.requestQuit(bundleId: target.bundleId)
      await note(target.slug, sent ? "quit requested" : "running, but no app process took the quit request")
    }
    return wasRunning
  }

  /// Polls until every quitting target is idle or `quitTimeout` has passed; returns the slugs still running.
  private func waitForQuit(_ targets: [Target]) async -> Set<String> {
    var left = await stillRunning(targets)
    var waited: Duration = .zero
    while !left.isEmpty, waited < Self.quitTimeout {
      await sleep(Self.pollInterval)
      waited += Self.pollInterval
      left = await stillRunning(left)
    }
    let stuck = Set(left.map(\.slug))
    let timeout = "did not quit in \(Self.quitTimeout.components.seconds) s"
    for target in targets {
      await note(target.slug, stuck.contains(target.slug) ? timeout : "closed")
    }
    return stuck
  }

  private func stillRunning(_ targets: [Target]) async -> [Target] {
    var left: [Target] = []
    for target in targets where await running.isRunning(bundleId: target.bundleId, profileDir: target.profileDir) {
      left.append(target)
    }
    return left
  }

  /// One applying pass (none without idle targets). A target counts as updated when the pass swapped it or its
  /// `pendingBuild` is gone without a failure (a quit-triggered pass may have installed it first).
  private func install(_ targets: [Target]) async -> [String: Verdict] {
    guard !targets.isEmpty else { return [:] }
    let decisions = await applier.applyPendingNow(manual: true)
    let stillPending = await pendingSlugs()
    var verdicts: [String: Verdict] = [:]
    for target in targets {
      let decision = decisions.first { $0.slug == target.slug } ?? decisions.first { $0.slug == "all" }
      let verdict = Self.verdict(decision, pendingCleared: stillPending.map { !$0.contains(target.slug) } ?? false)
      verdicts[target.slug] = verdict
      switch verdict {
      case .updated: await note(target.slug, "updated")
      case .failed(let detail): await note(target.slug, "update failed: \(detail)")
      case .notInstalled(let action): await note(target.slug, "not updated (\(action))")
      }
    }
    return verdicts
  }

  static func verdict(_ decision: UpdateDecision?, pendingCleared: Bool) -> Verdict {
    if let decision, decision.action == .fail { return .failed(shortDetail(decision.detail)) }
    if decision?.action == .swap || pendingCleared { return .updated }
    return .notInstalled(decision?.action.rawValue ?? "no-decision")
  }

  /// The first line of a decision detail, cut to `maxDetailLength` characters.
  public static func shortDetail(_ detail: String) -> String {
    let line = detail.split(separator: "\n").first.map(String.init) ?? detail
    return line.count > maxDetailLength ? String(line.prefix(maxDetailLength)) + "…" : line
  }

  /// Slugs whose `pendingBuild` is still set after the pass; nil when `instances.json` cannot be read.
  private func pendingSlugs() async -> Set<String>? {
    do {
      return Set(try await store.load().filter { $0.pendingBuild != nil }.map(\.slug.raw))
    } catch {
      await note("all", "cannot re-read instances.json: \(error)")
      return nil
    }
  }

  /// Reopens each target; returns a problem line per clone that could not be opened.
  private func reopen(_ targets: [Target]) async -> [String: String] {
    var failures: [String: String] = [:]
    for target in targets {
      do {
        try await opener.open(app: target.app)
        await note(target.slug, "reopened")
      } catch {
        await note(target.slug, "reopen failed: \(error)")
        failures[target.slug] = BuilderText.format("restart.reopen-failed", target.name)
      }
    }
    return failures
  }

  private func note(_ slug: String, _ detail: String) async {
    await log.write("restart \(slug): \(detail)", category: "updates")
  }
}
