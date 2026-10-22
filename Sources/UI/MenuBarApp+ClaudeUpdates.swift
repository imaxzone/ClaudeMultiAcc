import AppKit
import InstanceBuilder
import Support

/// The menu's ↻ and the automatic Claude update check: statuses reach the menu in order, a newly stored Claude starts
/// an applying update pass, and a failed manual check explains itself in an alert.
extension MenuBarApp {
  static func makeClaudeUpdates(paths: Paths, runner: ProcessRunning) -> ClaudeUpdateChecker {
    ClaudeUpdateChecker.live(
      paths: paths, runner: runner, appVersion: ReleaseNotice.runningVersion(infoDictionary: Bundle.main.infoDictionary))
  }

  /// Hooks the checker to the menu and the watcher, then starts its schedule (unless `CMACC_NO_CLAUDE_UPDATE_CHECK=1`).
  /// The checker calls its handlers one at a time; a stream keeps their order on the main actor, so a late
  /// «downloading» never overwrites «ready».
  func startClaudeUpdates(_ checker: ClaudeUpdateChecker, watcher: UpdateWatcher) async {
    let (statuses, continuation) = AsyncStream.makeStream(of: ClaudeUpdateStatus.self)
    await checker.onStatusChange { continuation.yield($0) }
    Task { @MainActor [weak self] in
      for await status in statuses {
        self?.claudeStatus = status
        self?.menu?.claudeUpdateChanged()
      }
    }
    await checker.onNewSource { [weak self] _ in
      await self?.claudeSourceArrived(watcher: watcher)
    }
    await checker.start()
  }

  /// A new Claude is stored: closed clones are rebuilt from it now, open ones when they quit (or with «Обновить»).
  /// The pass runs on its own so the check that found the version ends right away.
  private func claudeSourceArrived(watcher: UpdateWatcher) async {
    menu?.reload()
    Task { [weak self] in
      _ = await watcher.handleOfficialChange()
      self?.menu?.reload()
    }
  }

  /// ↻ in the menu: one manual check; a failure is shown in an alert (the status line turns red meanwhile).
  func checkClaudeNow() {
    guard let claudeUpdates else { return }
    Task {
      guard case .failed(let failure) = await claudeUpdates.checkNow(manual: true) else { return }
      let text = ClaudeUpdateText.failureAlert(failure)
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = text.title
      alert.informativeText = text.message
      _ = await ModalAlert.run(alert)
    }
  }
}
