import AppKit
import Foundation
import os
import Support

/// The invisible sign-in router. ClaudeMultiAcc owns `claude://` only while at least one clone waits for sign-in
/// (see `SignInRouter`); a sign-in link then goes to that clone, every other link to the official Claude unchanged.
/// When nobody waits any more the scheme goes back to the official Claude. No UI; every decision is logged redacted.
///
/// Wiring: create it with the live init, `start()` once the instance list is loaded, `handle(_:)` from
/// `application(_:open:)` (queued until `start()`), `instancesChanged()` after a registry reload, `cloneCreated(bundleId:)`
/// when the new-instance flow installs a clone, optionally `signInStateChanged()` when a profile changes, `stop()` on quit.
/// Clone launches, activations, deactivations and quits are observed from `NSWorkspace` by the live init itself.
@MainActor
public final class SignInRouterController {
  /// How often the waiting set is re-read while someone waits (sign-in finishing, the window ending).
  static let recheckInterval: Duration = .seconds(5)

  private let ownApp: URL
  private let instances: @MainActor () -> [Instance]
  private let ownership: SchemeOwnership
  private let delivery: URLDelivering
  private let profiles: SignInStateReading
  private let clock: any Clock
  private let runningBundleIds: @MainActor () -> Set<String>
  private let officialFallback: @Sendable () -> URL?
  private let reclaimer: Reclaimer?
  private let driver: ReclaimerDriver?
  private let observesWorkspace: Bool
  private let rechecks: Bool
  private var router = SignInRouter()
  private var candidates: [SignInCandidate] = []
  private var started = false
  private var pending: [URL] = []
  private var observers: [NSObjectProtocol] = []
  private var recheck: Task<Void, Never>?
  /// The last queued scheme or delivery operation; the next one awaits it.
  private var tail: Task<Void, Never>?
  private let log = AppLog.logger("sign-in-router")

  /// True while at least one clone waits for sign-in, i.e. while ClaudeMultiAcc keeps `claude://`.
  public private(set) var holdsScheme = false

  /// The live router: system LaunchServices, `NSWorkspace` delivery and observers, and a reclaimer that keeps the
  /// scheme while a clone waits (every Claude re-registers itself as the handler when it launches).
  public convenience init(
    paths: Paths, ownApp: URL, instances: @escaping @MainActor () -> [Instance], ownership: SchemeOwnership? = nil,
    delivery: URLDelivering = WorkspaceDelivery()
  ) {
    let ownership = ownership ?? .system(ownApp: ownApp)
    let reclaimer = Reclaimer(ownership: ownership, registryBundleIds: [])
    self.init(
      ownApp: ownApp, instances: instances, ownership: ownership, delivery: delivery,
      runningBundleIds: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) },
      officialFallback: { OfficialApp.installedDefault() },
      reclaimer: reclaimer, driver: ReclaimerDriver(reclaimer: reclaimer, home: paths.home), observesWorkspace: true,
      rechecks: true)
  }

  init(
    ownApp: URL, instances: @escaping @MainActor () -> [Instance], ownership: SchemeOwnership, delivery: URLDelivering,
    profiles: SignInStateReading = ProfileSignInReader(), clock: any Clock = SystemClock(),
    runningBundleIds: @escaping @MainActor () -> Set<String> = { [] }, officialFallback: @escaping @Sendable () -> URL? = { nil },
    reclaimer: Reclaimer? = nil, driver: ReclaimerDriver? = nil, observesWorkspace: Bool = false, rechecks: Bool = false
  ) {
    self.ownApp = ownApp
    self.instances = instances
    self.ownership = ownership
    self.delivery = delivery
    self.profiles = profiles
    self.clock = clock
    self.runningBundleIds = runningBundleIds
    self.officialFallback = officialFallback
    self.reclaimer = reclaimer
    self.driver = driver
    self.observesWorkspace = observesWorkspace
    self.rechecks = rechecks
  }

  // MARK: Wiring

  /// Call once the instance list is loaded. Running clones count as just launched; if nobody waits and a previous
  /// run (or the old link router) left `claude://` with ClaudeMultiAcc, it goes back to the official Claude. Links
  /// that arrived earlier are routed now.
  public func start() {
    guard !started else { return }
    started = true
    if observesWorkspace { observeWorkspace() }
    refreshCandidates()
    let now = clock.now
    let running = runningBundleIds()
    for candidate in candidates where running.contains(candidate.bundleId) {
      router.mark(bundleId: candidate.bundleId, at: now)
    }
    reevaluate()
    if !holdsScheme { returnSchemeIfOurs() }
    let queued = pending
    pending = []
    queued.forEach(route)
  }

  /// Stops observing and keeping the scheme, and hands it back if it is ours.
  public func stop() {
    guard started else { return }
    started = false
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers = []
    stopRechecks()
    driver?.setEnabled(false)
    holdsScheme = false
    returnSchemeIfOurs()
  }

  /// `stop()` for quitting: also waits until the scheme is handed back (a queued task would not run after exit).
  public func stopAndSettle() async {
    stop()
    await settle()
  }

  /// `claude://` URLs from `application(_:open:)`; queued until `start()`.
  public func handle(_ urls: [URL]) {
    guard started else {
      pending.append(contentsOf: urls)
      return
    }
    urls.forEach(route)
  }

  /// The registry changed (a clone added, removed or renamed).
  public func instancesChanged() {
    refreshCandidates()
    reevaluate()
  }

  /// The new-instance flow just installed this clone: it waits for sign-in until it signs in, quits or the window
  /// ends. Safe to call before the registry reload lists the clone; it waits from the next `instancesChanged()`.
  public func cloneCreated(bundleId: String) {
    refreshCandidates()
    router.mark(bundleId: bundleId, at: clock.now)
    reevaluate()
  }

  /// A profile may have signed in or out (e.g. its `config.json` changed): re-reads who waits right away instead of
  /// at the next re-check.
  public func signInStateChanged() { reevaluate() }

  // MARK: Clone activity (the live controller observes these itself)

  /// The NSWorkspace notifications the live controller follows.
  static let observedNotifications = [
    NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
    NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
  ]

  /// Launching, activating and leaving a clone (for the browser or Mail, to sign in) restart its wait; quitting ends it.
  func workspaceNotification(_ name: Notification.Name, bundleId: String) {
    name == NSWorkspace.didTerminateApplicationNotification ? cloneTerminated(bundleId: bundleId) : mark(bundleId)
  }

  func cloneLaunched(bundleId: String) { mark(bundleId) }

  func cloneActivated(bundleId: String) { mark(bundleId) }

  func cloneTerminated(bundleId: String) {
    router.forget(bundleId: bundleId)
    reevaluate()
  }

  /// Slugs of the clones waiting for sign-in, most recent first (diagnostics).
  public var waitingSlugs: [String] { currentWaiting().map(\.slug) }

  public func owner() -> (bundleId: String?, path: URL?) { ownership.owner() }

  /// Waits until every queued scheme change and delivery has finished (tests).
  func settle() async {
    while let current = tail {
      await current.value
      if tail == current { return }
    }
  }

  // MARK: Waiting

  private func mark(_ bundleId: String) {
    guard candidates.contains(where: { $0.bundleId == bundleId }) else { return }
    router.mark(bundleId: bundleId, at: clock.now)
    reevaluate()
  }

  private func refreshCandidates() {
    let all = instances()
    candidates = SignInCandidate.clones(from: all)
    if let reclaimer {
      let ids = Set(all.compactMap(\.bundleId))
      Task { await reclaimer.updateRegistry(ids) }
    }
  }

  private func currentWaiting() -> [SignInCandidate] {
    router.waiting(candidates, profiles: profiles, now: clock.now)
  }

  private func officialApp() -> URL? {
    OfficialApp.from(instances()) ?? officialFallback()
  }

  /// Takes or returns the scheme when the waiting set becomes non-empty or empty.
  func reevaluate() {
    guard started else { return }
    let waiting = currentWaiting()
    guard waiting.isEmpty == holdsScheme else { return }
    holdsScheme = !waiting.isEmpty
    if holdsScheme {
      let slugs = waiting.map(\.slug).joined(separator: ", ")
      log.info("Waiting for sign-in: [\(slugs, privacy: .public)]; taking claude://")
      takeScheme()
    } else {
      log.info("Nobody waits for sign-in; returning claude:// to the official Claude")
      stopRechecks()
      driver?.setEnabled(false)
      returnSchemeIfOurs()
    }
  }

  // MARK: Scheme

  private func takeScheme() {
    let ownership = self.ownership
    let log = self.log
    enqueue {
      switch await ownership.claim() {
      case .claimed: log.info("Took claude://")
      case .alreadyOwned: break
      case .failed(let message):
        log.error("Taking claude:// failed: \(SecretRedactor.redact(message), privacy: .public)")
      }
    }
    driver?.setEnabled(true)
    startRechecks()
  }

  private func returnSchemeIfOurs() {
    guard let official = officialApp() else {
      log.info("No official Claude app; claude:// stays as it is")
      return
    }
    let ownership = self.ownership
    let driver = self.driver
    let log = self.log
    enqueue {
      await driver?.quiesce()
      switch await ownership.handBack(to: official) {
      case .handedBack: log.info("Returned claude:// to the official Claude")
      case .notOurs: break
      case .failed(let message):
        log.error("Returning claude:// failed: \(SecretRedactor.redact(message), privacy: .public)")
      }
    }
  }

  private func startRechecks() {
    guard rechecks, recheck == nil else { return }
    recheck = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: SignInRouterController.recheckInterval) } catch { return }
        guard let self else { return }
        self.reevaluate()
      }
    }
  }

  private func stopRechecks() {
    recheck?.cancel()
    recheck = nil
  }

  // MARK: Links

  private func route(_ url: URL) {
    refreshCandidates()
    let waiting = currentWaiting()
    let kind = LinkClassifier.classify(url)
    let decision = SignInPolicy.decide(kind, waiting: waiting, official: officialApp(), ownApp: ownApp)
    log.info("Link \(kind.rawValue, privacy: .public) \(Redactor.redact(url), privacy: .public) → \(decision.logDescription, privacy: .public)")
    if case .clone(let slug, _) = decision, let clone = waiting.first(where: { $0.slug == slug }) {
      router.mark(bundleId: clone.bundleId, at: clock.now)
    }
    reevaluate()
    guard let app = decision.app else { return }
    let delivery = self.delivery
    let log = self.log
    enqueue {
      do {
        try await delivery.deliver(url, to: app, activate: true)
      } catch {
        log.error("Link delivery failed: \(WorkspaceDelivery.failureDetail(error), privacy: .public)")
      }
    }
  }

  /// Appends `operation` to the serial chain, so scheme changes and deliveries happen in the order they were decided.
  private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = tail
    tail = Task {
      await previous?.value
      await operation()
    }
  }

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    for name in Self.observedNotifications {
      let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        MainActor.assumeIsolated {
          guard let bundleId else { return }
          self?.workspaceNotification(name, bundleId: bundleId)
        }
      }
      observers.append(token)
    }
  }
}
