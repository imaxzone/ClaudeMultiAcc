import AppKit
import Support

/// One running copy of the app, as the single-instance check sees it.
public struct RunningInstance: Equatable, Sendable {
  public let pid: Int32
  public let launchDate: Date?

  public init(pid: Int32, launchDate: Date?) {
    self.pid = pid
    self.launchDate = launchDate
  }
}

/// Two copies with one bundle id (`dist/` and `~/Applications`, or a login item plus a manual start) must not both
/// run: the later launch quits quietly (R3).
public enum SingleInstance {
  /// The copy this process should yield to, or nil when it is the oldest. Copies are ordered by launch date
  /// (unknown dates count as latest), then by pid, so every copy reaches the same verdict.
  public static func olderCopy(own: RunningInstance, running: [RunningInstance]) -> RunningInstance? {
    running
      .filter { $0.pid != own.pid && isOlder($0, than: own) }
      .min { isOlder($0, than: $1) }
  }

  static func isOlder(_ lhs: RunningInstance, than rhs: RunningInstance) -> Bool {
    let left = lhs.launchDate ?? .distantFuture
    let right = rhs.launchDate ?? .distantFuture
    return left != right ? left < right : lhs.pid < rhs.pid
  }

  /// At launch: when an older copy runs, hands it the `claude://` links this process received and returns true
  /// (the caller then terminates). Unbundled runs (`swift run`) have no bundle id and are never stopped.
  @MainActor
  public static func yieldToOlderCopy(forwarding urls: [URL]) -> Bool {
    guard let bundleId = Bundle.main.bundleIdentifier else { return false }
    let current = NSRunningApplication.current
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { !$0.isTerminated }
    let own = RunningInstance(pid: current.processIdentifier, launchDate: current.launchDate)
    let running = apps.map { RunningInstance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
    guard let older = olderCopy(own: own, running: running) else { return false }
    let log = AppLog.logger("single-instance")
    log.notice("Another copy (pid \(older.pid, privacy: .public)) is already running; quitting this one")
    if !urls.isEmpty, let target = apps.first(where: { $0.processIdentifier == older.pid })?.bundleURL {
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      NSWorkspace.shared.open(urls, withApplicationAt: target, configuration: configuration, completionHandler: nil)
    }
    return true
  }
}
