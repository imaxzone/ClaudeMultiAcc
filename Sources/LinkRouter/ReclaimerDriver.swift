import AppKit
import Foundation
import Support

/// Feeds the `Reclaimer` from the live system while it is enabled: app launches, changes to the LaunchServices
/// secure plist (FSEvents) and a timer that wakes at `Reclaimer.nextWake()`. While disabled nothing is observed and
/// nothing runs. Every reclaimer operation goes through one serial chain (each awaits the previous), so a fast
/// off → on can never apply `stop` after `start`.
@MainActor
public final class ReclaimerDriver {
  nonisolated static let secureFile = "com.apple.launchservices.secure.plist"

  private let reclaimer: Reclaimer
  private let prefsDir: URL
  private var watcher: DirectoryWatcher?
  private var launchObserver: NSObjectProtocol?
  private var loop: Task<Void, Never>?
  /// The last cancelled loop: `quiesce()` waits for its in-flight claim.
  private var stoppedLoop: Task<Void, Never>?
  /// The last queued operation; the next one awaits it.
  private var tail: Task<Void, Never>?
  public private(set) var isActive = false

  public init(reclaimer: Reclaimer, home: URL) {
    self.reclaimer = reclaimer
    prefsDir = home.appendingPathComponent("Library/Preferences/com.apple.LaunchServices", isDirectory: true)
  }

  /// Whether the wait loop is running (tests).
  var isLooping: Bool { loop.map { !$0.isCancelled } ?? false }

  /// Waits until every queued operation has been applied (tests).
  func settle() async {
    await tail?.value
  }

  /// Waits until queued operations and any claim started by a cancelled loop are finished, so a caller that just
  /// disabled the driver can hand the scheme back without a late claim taking it again.
  public func quiesce() async {
    await stoppedLoop?.value
    await tail?.value
  }

  /// Appends `operation` to the serial chain and returns its task.
  @discardableResult
  private func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    let previous = tail
    let task = Task {
      await previous?.value
      await operation()
    }
    tail = task
    return task
  }

  /// Starts or stops keeping the scheme.
  public func setEnabled(_ enabled: Bool) {
    guard enabled != isActive else { return }
    enabled ? activate() : deactivate()
  }

  private func activate() {
    isActive = true
    let reclaimer = self.reclaimer
    launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
      MainActor.assumeIsolated {
        guard let bundleId else { return }
        self?.poke { await reclaimer.appLaunched(bundleId: bundleId) }
      }
    }
    let watcher = DirectoryWatcher(paths: [prefsDir]) { [weak self] urls in
      guard urls.contains(where: { $0.lastPathComponent == Self.secureFile }) else { return }
      Task { @MainActor in self?.poke { await reclaimer.prefsChanged() } }
    }
    watcher.start()
    self.watcher = watcher
    poke { await reclaimer.start() }
  }

  private func deactivate() {
    isActive = false
    watcher?.stop()
    watcher = nil
    if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
    launchObserver = nil
    loop?.cancel()
    stoppedLoop = loop
    loop = nil
    let reclaimer = self.reclaimer
    enqueue { await reclaimer.stop() }
  }

  /// Queues `event`, then restarts the wait loop after it so a new earlier due time is honoured. Each loop first
  /// waits for the cancelled one it replaces, so awaiting the newest loop covers every claim in flight.
  private func poke(_ event: @escaping @Sendable () async -> Void) {
    guard isActive else { return }
    let previous = loop
    previous?.cancel()
    let reclaimer = self.reclaimer
    let applied = enqueue(event)
    loop = Task {
      await previous?.value
      await applied.value
      while !Task.isCancelled {
        await reclaimer.runDue()
        guard let wake = await reclaimer.nextWake() else { return }
        let delay = max(0.2, wake.timeIntervalSinceNow)
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      }
    }
  }
}
