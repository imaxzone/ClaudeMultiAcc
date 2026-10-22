import Foundation

/// When the reclaimer tries to take the `claude` scheme back (only while ownership is enabled).
public struct ReclaimSchedule: Sendable, Equatable {
  /// A Claude app re-registers itself shortly after launch; retry at these offsets.
  public let launchOffsets: [TimeInterval]
  /// After the LaunchServices secure plist changes.
  public let prefsDelay: TimeInterval
  public let pollInterval: TimeInterval
  public let maxClaims: Int
  public let rateWindow: TimeInterval
  public let backoffBase: TimeInterval
  public let backoffCap: TimeInterval
  /// Consecutive failures after which the reclaimer stops until the next wait starts.
  public let maxFailures: Int

  public init(
    launchOffsets: [TimeInterval] = [2, 6, 12, 25], prefsDelay: TimeInterval = 1, pollInterval: TimeInterval = 60,
    maxClaims: Int = 6, rateWindow: TimeInterval = 60, backoffBase: TimeInterval = 60, backoffCap: TimeInterval = 30 * 60,
    maxFailures: Int = 3
  ) {
    self.launchOffsets = launchOffsets
    self.prefsDelay = prefsDelay
    self.pollInterval = pollInterval
    self.maxClaims = maxClaims
    self.rateWindow = rateWindow
    self.backoffBase = backoffBase
    self.backoffCap = backoffCap
    self.maxFailures = maxFailures
  }

  public func afterLaunch(at t: Date) -> [Date] {
    launchOffsets.map { t.addingTimeInterval($0) }
  }

  public func afterPrefsChange(at t: Date) -> Date {
    t.addingTimeInterval(prefsDelay)
  }

  /// At most `maxClaims` claims in the rolling window ending at `now`.
  public func allow(now: Date, history: [Date]) -> Bool {
    inWindow(now: now, history: history).count < maxClaims
  }

  /// The earliest time `allow` becomes true again.
  public func nextAllowed(now: Date, history: [Date]) -> Date {
    let recent = inWindow(now: now, history: history).sorted()
    guard recent.count >= maxClaims else { return now }
    return recent[recent.count - maxClaims].addingTimeInterval(rateWindow)
  }

  /// 60 s after the first failure, doubling per further failure, capped at 30 min.
  public func backoff(afterFailures n: Int) -> TimeInterval {
    guard n > 0 else { return 0 }
    return min(backoffBase * pow(2, Double(min(n - 1, 30))), backoffCap)
  }

  private func inWindow(now: Date, history: [Date]) -> [Date] {
    history.filter { now.timeIntervalSince($0) < rateWindow && $0 <= now }
  }
}
