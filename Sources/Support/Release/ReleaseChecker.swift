import Foundation

/// What one `checkIfDue()` call decided.
public struct ReleaseCheckOutcome: Sendable, Equatable {
  /// The release to offer, if one newer than the running app is known.
  public let available: AppReleaseInfo?
  /// Earliest moment the next request may go out.
  public let nextCheck: Date
  /// How long to wait before calling `checkIfDue()` again (at least a minute).
  public let wait: Duration
}

/// Asks GitHub at most once per 24 hours whether a newer ClaudeMultiAcc release exists. Every answer and the time
/// of every request are cached in `release-check.json`, so a relaunch neither re-asks nor forgets the notice.
/// 404 (no releases), rate limits (403/429), other statuses and network errors never offer anything new and never
/// throw; each kind of failure is logged once per process.
public actor ReleaseChecker {
  public static let interval: TimeInterval = 24 * 60 * 60
  public static let minimumWait: TimeInterval = 60

  private let store: ReleaseStateStore
  private let fetcher: any ReleaseFetching
  private let clock: any Clock
  private let current: ReleaseVersion?
  private let log = AppLog.logger("release-check")
  private var loggedFailures: Set<String> = []
  private var inFlight: Task<ReleaseCheckOutcome, Never>?

  public init(stateFile: URL, fetcher: any ReleaseFetching, clock: any Clock = SystemClock(), currentVersion: String) {
    store = ReleaseStateStore(file: stateFile)
    self.fetcher = fetcher
    self.clock = clock
    current = ReleaseVersion(currentVersion)
  }

  /// The release to offer from the cache alone (no network), e.g. right after launch.
  public func cached() -> AppReleaseInfo? {
    offer(store.load().latest)
  }

  /// Requests GitHub when 24 hours passed since the last request (or the clock went backwards); otherwise answers
  /// from the cache. Overlapping calls share one pass, so they never send two requests.
  public func checkIfDue() async -> ReleaseCheckOutcome {
    if let inFlight { return await inFlight.value }
    let pass = Task { await self.runPass() }
    inFlight = pass
    let outcome = await pass.value
    inFlight = nil
    return outcome
  }

  private func runPass() async -> ReleaseCheckOutcome {
    let state = store.load()
    let now = clock.now
    guard Self.isDue(lastCheck: state.lastCheck, now: now) else { return outcome(state) }
    let updated = await refresh(state.with(lastCheck: now))
    store.save(updated)
    return outcome(updated)
  }

  static func isDue(lastCheck: Date?, now: Date) -> Bool {
    guard let lastCheck else { return true }
    return lastCheck > now || now.timeIntervalSince(lastCheck) >= interval
  }

  private func refresh(_ state: ReleaseCheckState) async -> ReleaseCheckState {
    do {
      return apply(try await fetcher.fetchLatest(etag: state.etag), to: state)
    } catch {
      logFailure("network", "Release check failed: \(error.localizedDescription)")
      return state
    }
  }

  private func apply(_ response: ReleaseHTTPResponse, to state: ReleaseCheckState) -> ReleaseCheckState {
    switch response.status {
    case 200:
      return parse(response, into: state)
    case 304:
      return state
    case 404:
      logFailure("not-found", "No ClaudeMultiAcc releases published yet")
      return state.with(etag: nil, latest: nil)
    case 403, 429:
      logFailure("rate-limit", "Release check refused by GitHub (HTTP \(response.status)); retrying tomorrow")
      return state
    default:
      logFailure("http-\(response.status)", "Release check got HTTP \(response.status)")
      return state
    }
  }

  /// A stable release replaces the cache with its `ETag`; anything else keeps the last release seen and drops the
  /// `ETag`, so the next request fetches in full.
  private func parse(_ response: ReleaseHTTPResponse, into state: ReleaseCheckState) -> ReleaseCheckState {
    let payload: ReleasePayload
    do {
      payload = try ReleasePayload.decode(response.body)
    } catch {
      logFailure("parse", "Release answer unreadable: \(String(describing: error))")
      return state.with(etag: nil, latest: state.latest)
    }
    guard payload.isStable else { return state.with(etag: nil, latest: state.latest) }
    guard let release = payload.release else {
      logFailure("invalid", "Release ignored: tag or page is not a ClaudeMultiAcc release")
      return state.with(etag: nil, latest: state.latest)
    }
    return state.with(etag: response.etag, latest: release)
  }

  private func outcome(_ state: ReleaseCheckState) -> ReleaseCheckOutcome {
    let nextCheck = (state.lastCheck ?? clock.now).addingTimeInterval(Self.interval)
    let seconds = max(Self.minimumWait, nextCheck.timeIntervalSince(clock.now)).rounded(.up)
    return ReleaseCheckOutcome(available: offer(state.latest), nextCheck: nextCheck, wait: .seconds(Int64(seconds)))
  }

  /// `release` as a notice when it is newer than the running app and its page is a project release page.
  private func offer(_ release: ReleaseCheckState.Release?) -> AppReleaseInfo? {
    guard let release, let current, let version = ReleaseVersion(release.version), version > current,
      ReleasePage.isAllowed(release.pageURL)
    else { return nil }
    return AppReleaseInfo(version: version.description, pageURL: release.pageURL)
  }

  private func logFailure(_ kind: String, _ message: String) {
    guard loggedFailures.insert(kind).inserted else { return }
    log.notice("\(message, privacy: .public)")
  }
}
