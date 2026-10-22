import AppKit
import InstanceBuilder
import LinkRouter
import Observation
import os
import Support

/// Assembles the live app: the instance list, the status-item menu, the update watcher and the restart flow, the
/// «Изменить… / Добавить» window, the login-item switch, the invisible sign-in router and the release check.
@MainActor
public final class MenuBarApp {
  /// How long quitting waits for `claude://` to be handed back and for a running update pass to end.
  static let handBackTimeout: Duration = .seconds(3)
  static let passTimeout: Duration = .seconds(30)
  /// `lsregister -dump` output allowed for the start-up LaunchServices sweep.
  nonisolated static let sweepOutputLimit = 64 * 1024 * 1024

  private let paths: Paths
  private let settingsStore: SettingsStore
  private let list: InstanceList
  private let runner = SystemProcessRunner()
  private let launcher = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CloneLauncher")
  private var statusItem: StatusItemController?
  private(set) var menu: AppMenuController?
  private var actions: AppActions?
  private var updateWatcher: UpdateWatcher?
  private var signIn: SignInRouterController?
  private var releaseNotice: ReleaseNotice?
  private var deleteFlow: DeleteFlow?
  private var updates: UpdateFlow?
  /// The Claude update check behind the menu's ↻ (`MenuBarApp+ClaudeUpdates`).
  private(set) var claudeUpdates: ClaudeUpdateChecker?
  /// Its last status, in the order it reported them; the menu reads it.
  var claudeStatus: ClaudeUpdateStatus = .idle
  private var workspaceObservers: [NSObjectProtocol] = []
  private let log = AppLog.logger("menu-bar-app")

  public init(paths: Paths = .live()) {
    self.paths = paths
    settingsStore = SettingsStore(file: paths.settingsFile)
    list = InstanceList(paths: paths)
  }

  public func start() {
    guard offerMove() != .relaunching else {
      NSApp.terminate(nil)
      return
    }
    do {
      try paths.ensureDataDirs()
    } catch {
      log.error("Cannot create data dirs: \(String(describing: error), privacy: .public)")
    }
    let list = self.list
    let watcher = UpdateWatcher.live(paths: paths, runner: runner, launcherBinary: launcher)
    updateWatcher = watcher
    signIn = makeSignInRouter()
    let releaseNotice = ReleaseNotice.live(paths: paths)
    self.releaseNotice = releaseNotice
    let deleteFlow = DeleteFlow.live(paths: paths, runner: runner)
    self.deleteFlow = deleteFlow
    let updates = makeUpdateFlow(watcher: watcher)
    self.updates = updates
    let claudeUpdates = Self.makeClaudeUpdates(paths: paths, runner: runner)
    self.claudeUpdates = claudeUpdates

    let editor = InstanceEditorWindowController(
      paths: paths, launcherBinary: launcher, ensureSigning: ensureSigning,
      onChange: { [weak self] instance in self?.instanceSaved(instance) })
    let actions = AppActions(
      list: list, updates: updates, editor: editor, remove: { [weak self] slug in self?.delete(slug: slug) },
      checkClaude: { [weak self] in self?.checkClaudeNow() })
    let menu = AppMenuController(
      instances: { list.instances }, login: LaunchAtLoginController(home: paths.home), actions: actions,
      releaseInfo: { releaseNotice.available },
      busy: { AppMenuBusy(updating: updates.isRunning, deleting: deleteFlow.deleting) },
      claudeUpdate: { [weak self] in self?.claudeStatus ?? .idle },
      newestClaude: { [paths] in ClaudeSourceStore(paths: paths).newest()?.version })
    // A clone being deleted is not updated with the others.
    actions.behindSlugs = { [weak menu] in
      (menu?.model.content.banner?.slugs ?? []).filter { !deleteFlow.deleting.contains($0) }
    }
    self.actions = actions
    self.menu = menu
    statusItem = StatusItemController(menu: menu)

    list.onChange = { [weak self] in self?.instancesChanged() }
    releaseNotice.onChange = { [weak menu] in menu?.reload() }
    updates.onRunningChange = { [weak menu] in menu?.busyChanged() }
    observeDeleting(deleteFlow)
    observeWorkspace()
    Task { await self.boot(watcher: watcher, claudeUpdates: claudeUpdates) }
  }

  /// Before quitting: hands `claude://` back if a clone was still waiting for sign-in (a queued task would never run
  /// after exit), stops the watchers and lets a running update pass end, so no clone is left half swapped.
  public func shutdown() async {
    releaseNotice?.stop()
    await claudeUpdates?.stop()
    list.stop()
    if let signIn {
      await Self.waitAtMost(Self.handBackTimeout) { await signIn.stopAndSettle() }
    }
    if let updateWatcher {
      await updateWatcher.stop()
      if !(await updateWatcher.waitUntilIdle(timeout: Self.passTimeout)) {
        log.error("Quitting while an update pass still runs")
      }
    }
  }

  private func boot(watcher: UpdateWatcher, claudeUpdates: ClaudeUpdateChecker) async {
    await list.start()
    // Backups and staged builds must never be offered by macOS as apps; the dump runs to ~16 MB on a busy Mac.
    let paths = self.paths
    Task.detached(priority: .utility) {
      await LaunchServicesCleanup.sweep(paths: paths, runner: SystemProcessRunner(outputLimit: Self.sweepOutputLimit))
    }
    signIn?.start()
    releaseNotice?.start()
    await watcher.onPassFinished { [weak self] in await self?.list.reload() }
    await watcher.start()
    log.info("Started with \(self.list.instances.count, privacy: .public) instances")
    await startClaudeUpdates(claudeUpdates, watcher: watcher)
    // Claude may have updated while ClaudeMultiAcc was not running: one pass now, not in an hour.
    _ = await watcher.handleOfficialChange()
  }

  /// `claude://` URLs from `application(_:open:)`; the router queues them until it has started.
  public func handle(urls: [URL]) {
    signIn?.handle(urls)
  }

  /// Asks to move to Applications when started from a download, the Desktop or a disk image; «Не сейчас» is
  /// remembered for that copy.
  private func offerMove() -> MoveToApplications.Outcome {
    let declined = (try? Data(contentsOf: paths.settingsFile))
      .flatMap { try? JSONCoding.decoder.decode(AppSettings.self, from: $0) }?.ui.moveDeclinedPath
    let outcome = MoveToApplications.offerIfNeeded(home: paths.home, declinedPath: declined)
    if case .declined(let path) = outcome {
      let store = settingsStore
      Task {
        _ = try? await store.update { settings in
          var settings = settings
          settings.ui.moveDeclinedPath = path
          return settings
        }
      }
    }
    return outcome
  }

  /// No router for a translocated copy: its path disappears when it quits, and `claude://` must never point there.
  private func makeSignInRouter() -> SignInRouterController? {
    let bundle = Bundle.main.bundleURL
    guard TranslocationCheck.liveLocation(of: bundle, home: paths.home) != .translocated else {
      log.info("Translocated copy: the sign-in router stays off")
      return nil
    }
    let list = self.list
    return SignInRouterController(paths: paths, ownApp: bundle, instances: { list.instances })
  }

  /// The permanent identity clones are signed with: the owner's existing one, or one the app creates once in its own
  /// keychain (no Terminal, no login-keychain password). Runs before every build.
  private var ensureSigning: @Sendable () async throws -> SigningIdentity {
    let provisioner = SigningIdentityProvisioner(paths: paths, runner: runner)
    return { try await provisioner.ensureIdentity() }
  }

  private func makeUpdateFlow(watcher: UpdateWatcher) -> UpdateFlow {
    let store = InstanceStore(paths: paths)
    let restarter = CloneRestarter.live(paths: paths, runner: runner, applier: watcher)
    let ensureSigning = self.ensureSigning
    let services = UpdateFlowServices(
      ensureSigning: { _ = try await ensureSigning() },
      applyPending: { await watcher.applyPendingNow(manual: true) },
      loadInstances: { try await store.load() },
      restart: { await restarter.restart(slugs: $0) })
    return UpdateFlow(services: services, settings: settingsStore, dialogs: AlertUpdateDialogs()) { [weak self] in
      await self?.list.reload()
    }
  }

  private func instancesChanged() {
    menu?.reload()
    signIn?.instancesChanged()
  }

  /// After «Создать» / «Сохранить»: the new entry is in `instances.json`; a new clone may now wait for sign-in.
  private func instanceSaved(_ instance: Instance) {
    if let bundleId = instance.bundleId { signIn?.cloneCreated(bundleId: bundleId) }
    Task { await list.reload() }
  }

  /// «Удалить «…»…»: asks «Только приложение / Всё», quits the clone, moves everything to the Trash.
  private func delete(slug: String) {
    guard let deleteFlow else { return }
    Task {
      if case .finished(let report) = await deleteFlow.delete(slug: slug), report.recordRemoved {
        await list.reload()
      }
    }
  }

  /// «удаляется» on the tile and the status item while `DeleteFlow` removes a clone.
  private func observeDeleting(_ flow: DeleteFlow) {
    withObservationTracking {
      _ = flow.deleting
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.menu?.busyChanged()
        self?.observeDeleting(flow)
      }
    }
  }

  private func observeWorkspace() {
    let center = NSWorkspace.shared.notificationCenter
    let token = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
      [weak self] note in
      let quit = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
      MainActor.assumeIsolated {
        if let quit { self?.cloneDidQuit(bundleId: quit) }
      }
    }
    workspaceObservers.append(token)
  }

  /// A clone whose new build waited for it to quit gets that build right away; other apps are ignored here.
  private func cloneDidQuit(bundleId: String) {
    guard let updateWatcher, list.instances.contains(where: { $0.kind == .clone && $0.bundleId == bundleId }) else {
      return
    }
    Task {
      let decisions = await updateWatcher.cloneDidQuit(bundleId: bundleId)
      if !decisions.isEmpty { await list.reload() }
    }
  }

  /// Runs `operation`, but returns after `timeout` at the latest (the operation keeps running).
  private static func waitAtMost(_ timeout: Duration, _ operation: @escaping @MainActor () async -> Void) async {
    let work = Task { @MainActor in await operation() }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await work.value }
      group.addTask { try? await Task.sleep(for: timeout) }
      await group.next()
      group.cancelAll()
    }
  }
}
