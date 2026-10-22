import Foundation
import Support

public enum ReclaimStatus: Sendable, Equatable {
  case idle
  case holding
  case failing(Int)
  /// Gave up after `maxFailures` consecutive failures; the next `start()` tries again.
  case stopped
}

/// Keeps the `claude` scheme between `start()` and `stop()` (while a clone waits for sign-in): claims at start, after
/// registry apps launch (every Claude re-registers itself as the handler), after the LaunchServices prefs change and on
/// a poll, rate-limited and backed off. Stopped → never calls `setHandler`.
/// Time is driven from outside: callers invoke `runDue()` at `nextWake()` (see `ReclaimerDriver`).
public actor Reclaimer {
  private let ownership: SchemeOwnership
  private let schedule: ReclaimSchedule
  private let clock: any Clock
  private var registryBundleIds: Set<String>
  private let onStatus: @Sendable (ReclaimStatus) -> Void
  private var active = false
  private var dues: Set<Date> = []
  private var nextPoll: Date?
  private var history: [Date] = []
  private var failures = 0
  private var backoffUntil: Date?
  public private(set) var status: ReclaimStatus = .idle
  /// Bumped by `start`/`stop`: a `runDue` suspended across one of them must not record or reschedule afterwards.
  private var epoch = 0
  private let log = AppLog.logger("reclaimer")

  public init(
    ownership: SchemeOwnership, schedule: ReclaimSchedule = ReclaimSchedule(), clock: any Clock = SystemClock(),
    registryBundleIds: Set<String>, onStatus: @escaping @Sendable (ReclaimStatus) -> Void = { _ in }
  ) {
    self.ownership = ownership
    self.schedule = schedule
    self.clock = clock
    self.registryBundleIds = registryBundleIds
    self.onStatus = onStatus
  }

  public var isActive: Bool { active }

  public func updateRegistry(_ bundleIds: Set<String>) {
    registryBundleIds = bundleIds
  }

  /// Resets failure state and schedules an immediate claim plus the poll.
  public func start() {
    active = true
    epoch += 1
    failures = 0
    backoffUntil = nil
    dues = [clock.now]
    nextPoll = clock.now.addingTimeInterval(schedule.pollInterval)
    update(.idle)
  }

  /// Nobody waits any more: forget all work and any "stopped" verdict.
  public func stop() {
    active = false
    epoch += 1
    failures = 0
    backoffUntil = nil
    dues = []
    nextPoll = nil
    update(.idle)
  }

  public func appLaunched(bundleId: String) {
    guard active, registryBundleIds.contains(bundleId), status != .stopped else { return }
    dues.formUnion(schedule.afterLaunch(at: clock.now))
  }

  public func prefsChanged() {
    guard active, status != .stopped else { return }
    dues.insert(schedule.afterPrefsChange(at: clock.now))
  }

  public func nextWake() -> Date? {
    (Array(dues) + [nextPoll].compactMap { $0 }).min()
  }

  /// Claims once if anything is due, honouring backoff and the rate limit (deferred work is rescheduled). The due
  /// items are taken before the first suspension, so overlapping calls never claim twice for one item.
  public func runDue() async {
    let now = clock.now
    let pollDue = nextPoll.map { $0 <= now } ?? false
    guard active, status != .stopped, pollDue || dues.contains(where: { $0 <= now }) else { return }
    dues = dues.filter { $0 > now }
    if pollDue { nextPoll = now.addingTimeInterval(schedule.pollInterval) }
    if let until = backoffUntil, now < until { return postpone(to: until) }
    guard schedule.allow(now: now, history: history) else {
      return postpone(to: schedule.nextAllowed(now: now, history: history))
    }
    let started = epoch
    let result = await ownership.claim()
    guard epoch == started else { return }
    handle(result, at: now)
  }

  private func handle(_ result: ClaimResult, at now: Date) {
    switch result {
    case .claimed:
      history.append(now)
      failures = 0
      log.info("Claimed the claude scheme")
      update(.holding)
    case .alreadyOwned:
      failures = 0
      update(.holding)
    case .failed(let message):
      history.append(now)
      failures += 1
      log.error("Claiming the claude scheme failed (\(self.failures, privacy: .public)): \(SecretRedactor.redact(message), privacy: .public)")
      if failures >= schedule.maxFailures {
        dues = []
        nextPoll = nil
        update(.stopped)
      } else {
        backoffUntil = now.addingTimeInterval(schedule.backoff(afterFailures: failures))
        update(.failing(failures))
      }
    }
    history = history.filter { now.timeIntervalSince($0) < schedule.rateWindow }
  }

  private func postpone(to date: Date) {
    dues.insert(date)
  }

  private func update(_ new: ReclaimStatus) {
    guard new != status else { return }
    status = new
    onStatus(new)
  }
}
