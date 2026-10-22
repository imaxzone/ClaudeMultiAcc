import AppKit
import InstanceBuilder
import os
import Support

/// The status-item menu: a panel with the Claude update header (↻), the update banner, the grid of app icons and the
/// rows below it. Re-reads the instance list, installed versions, login item, release info, busy state and the Claude
/// update check on every open; between opens, `reload()` keeps the model (and so the status item's dot and label)
/// current, `busyChanged()` shows an update run or a removal starting or ending, and `claudeUpdateChanged()` follows
/// the Claude update check.
@MainActor
public final class AppMenuController {
  public let model = AppMenuModel()
  /// `true` when the panel opens, `false` when it closes (the status item highlights its button meanwhile).
  public var onVisibilityChange: ((Bool) -> Void)?

  private let instances: @MainActor () -> [Instance]
  private let login: any LaunchAtLoginToggle
  private let actions: any AppMenuActions
  private let releaseInfo: @MainActor () -> AppReleaseInfo?
  private let busy: @MainActor () -> AppMenuBusy
  private let claudeUpdate: @MainActor () -> ClaudeUpdateStatus
  private let newestClaude: @MainActor () -> String?
  private let versions: any AppVersionReading
  private let icons: any AppIconLoading
  let anchors = AppMenuAnchors()
  private let presenter: any AppTileMenuPresenting
  private var panel: AppMenuPanelController?
  /// The chosen tile menu's target; menu items hold their target weakly.
  private var menuTarget: AppTileMenuTarget?
  /// Between `prepareToOpen()` and `close()`.
  private var isShowing = false
  /// The Claude check's result (`isTransient`) the open panel shows; once the panel closes it is dismissed.
  private var shownClaudeResult: ClaudeUpdateStatus?
  /// A result the owner saw in a panel since closed: it reads as idle until a new check runs.
  private var dismissedClaudeResult: ClaudeUpdateStatus?
  private let log = AppLog.logger("app-menu")

  /// - Parameters:
  ///   - instances: the current `instances.json` list (read on every open and on `reload()`).
  ///   - actions: kept strongly.
  ///   - releaseInfo: a newer ClaudeMultiAcc release, read on every open and on `reload()`.
  ///   - busy: what is running (`UpdateFlow.isRunning`, `DeleteFlow.deleting`), read on every open, on `reload()` and
  ///     on `busyChanged()`.
  ///   - claudeUpdate: the Claude update check's status, read on every open, on `reload()` and on
  ///     `claudeUpdateChanged()`.
  ///   - newestClaude: the version of the newest Claude the clones are built from (a verified download newer than the
  ///     official app, `ClaudeSourceStore.newest()`); nil means the official app's version. The banner, the tiles'
  ///     arrows and the header's idle line use it. Read on every open and on `reload()`.
  public convenience init(
    instances: @escaping @MainActor () -> [Instance], login: any LaunchAtLoginToggle, actions: any AppMenuActions,
    releaseInfo: @escaping @MainActor () -> AppReleaseInfo? = { nil },
    busy: @escaping @MainActor () -> AppMenuBusy = { .idle },
    claudeUpdate: @escaping @MainActor () -> ClaudeUpdateStatus = { .idle },
    newestClaude: @escaping @MainActor () -> String? = { nil },
    versions: any AppVersionReading = InstalledAppVersions(), icons: any AppIconLoading = BundleIconLoader()
  ) {
    self.init(
      instances: instances, login: login, actions: actions, releaseInfo: releaseInfo, busy: busy,
      claudeUpdate: claudeUpdate, newestClaude: newestClaude, versions: versions, icons: icons, presenter: nil)
  }

  init(
    instances: @escaping @MainActor () -> [Instance], login: any LaunchAtLoginToggle, actions: any AppMenuActions,
    releaseInfo: @escaping @MainActor () -> AppReleaseInfo?, busy: @escaping @MainActor () -> AppMenuBusy = { .idle },
    claudeUpdate: @escaping @MainActor () -> ClaudeUpdateStatus = { .idle },
    newestClaude: @escaping @MainActor () -> String? = { nil },
    versions: any AppVersionReading, icons: any AppIconLoading, presenter: (any AppTileMenuPresenting)?
  ) {
    self.instances = instances
    self.login = login
    self.actions = actions
    self.releaseInfo = releaseInfo
    self.busy = busy
    self.claudeUpdate = claudeUpdate
    self.newestClaude = newestClaude
    self.versions = versions
    self.icons = icons
    self.presenter = presenter ?? AnchoredTileMenuPresenter(anchors: anchors)
  }

  /// A clone is behind the newest Claude (the status item's red dot).
  public var hasUpdates: Bool { model.content.hasUpdates }
  public var isOpen: Bool { panel?.isVisible ?? false }

  /// Re-reads the instance list, installed versions and icons (cheap, synchronous file reads), the newest Claude,
  /// the release, the busy state and the Claude update check. Call it when `instances.json` changes, a clone was
  /// rebuilt, a Claude was downloaded or a release was found, so the status item and an open panel stay right.
  public func reload() {
    let list = instances()
    let versions = self.versions
    let official = list.first { $0.kind == .official }?.appPath.flatMap { versions.version(appPath: $0) }
    // Clones are built from the newest Claude: a verified download when it is newer than the official app.
    let target = newestClaude().flatMap { $0.isEmpty ? nil : $0 } ?? official
    let content = AppMenuContentBuilder.build(instances: list, officialVersion: target) { instance in
      instance.appPath.flatMap { versions.version(appPath: $0) }
    }
    if content != model.content { model.content = content }
    if target != model.claudeVersion { model.claudeVersion = target }
    let loaded = Dictionary(uniqueKeysWithValues: content.tiles.compactMap { tile in
      icons.icon(for: tile.icon).map { (tile.slug, $0) }
    })
    if loaded != model.icons { model.icons = loaded }
    let release = releaseInfo()
    if release != model.release { model.release = release }
    busyChanged()
    claudeUpdateChanged()
  }

  /// Re-reads only the busy state (no file reads): the open panel and the status item follow. Call it when an
  /// update run or a removal starts and when it ends.
  public func busyChanged() {
    let now = busy()
    if now != model.busy { model.busy = now }
  }

  /// Re-reads only the Claude update check (no file reads): the header's line and ↻ follow. Call it whenever the
  /// check's status changes. A result (`upToDate`, `ready`, `failed`) stays while the panel is open and reads as idle
  /// once the panel was closed and opened again; a new check (a working status) clears that.
  public func claudeUpdateChanged() {
    let now = claudeUpdate()
    if now.isWorking {
      dismissedClaudeResult = nil
      shownClaudeResult = nil
    }
    let shown: ClaudeUpdateStatus = now.isTransient && now == dismissedClaudeResult ? .idle : now
    if isShowing, shown.isTransient { shownClaudeResult = shown }
    if shown != model.claudeUpdate { model.claudeUpdate = shown }
  }

  /// Everything the panel shows, fresh: login item, release, instances, versions, busy state and the Claude check.
  func prepareToOpen() {
    isShowing = true
    login.refresh()
    model.login = AppMenuLoginRow(login)
    reload()
    model.highlight = nil
    model.menuTile = nil
  }

  public func toggle(relativeTo button: NSStatusBarButton) {
    if isOpen { close() } else { open(relativeTo: button) }
  }

  public func open(relativeTo button: NSStatusBarButton) {
    prepareToOpen()
    let panel = self.panel ?? makePanel()
    self.panel = panel
    panel.show(below: button)
    onVisibilityChange?(true)
  }

  public func close() {
    model.highlight = nil
    if isShowing {
      isShowing = false
      if let shownClaudeResult { dismissedClaudeResult = shownClaudeResult }
      shownClaudeResult = nil
    }
    guard let panel, panel.isVisible else { return }
    panel.close()
    onVisibilityChange?(false)
  }

  private func makePanel() -> AppMenuPanelController {
    let view = AppMenuView(
      model: model, anchors: anchors,
      actions: AppMenuViewActions(
        activate: { [weak self] in self?.activate($0) },
        perform: { [weak self] command, slug in self?.perform(command, slug: slug) }))
    let panel = AppMenuPanelController(root: view, model: model)
    let window = panel.panel
    panel.onKey = { [weak self] command in self?.handle(command) ?? false }
    panel.onSecondaryClick = { [weak self, weak window] point in
      guard let self, let window else { return false }
      return self.secondaryClick(at: point, in: window)
    }
    panel.onDismiss = { [weak self] in self?.close() }
    panel.isBusy = { [weak self] in self?.model.menuTile != nil }
    return panel
  }

  // MARK: Commands

  /// Keyboard: moves the highlight, activates it (⌥Return: opens the highlighted tile's app), closes, quits.
  @discardableResult
  func handle(_ command: AppMenuKeyCommand) -> Bool {
    switch command {
    case .close: close()
    case .quit: activate(.quit)
    case .activate:
      guard let item = model.highlight?.item else { return true }
      activate(item)
    case .openApp:
      guard case .tile(let slug)? = model.highlight?.item, !model.busy.isDeleting(slug) else { return true }
      perform(.open, slug: slug)
    default:
      let next = AppMenuNavigation.target(from: model.highlight?.item, command, in: model.layout)
      model.highlight = next.map { AppMenuHighlight(item: $0, byKeyboard: true) }
    }
    return true
  }

  func activate(_ item: AppMenuItem) {
    switch item {
    case .checkClaude:
      // ↻ is disabled while a check runs; the menu stays open to show the check's progress and result.
      guard !model.claudeUpdate.isWorking else { return }
      actions.checkClaudeUpdates()
    case .updateAll:
      // The button is disabled while an update runs; Return on it does nothing either.
      guard !model.busy.updating else { return }
      close()
      actions.updateAll()
    case .tile(let slug):
      showActions(slug)
    case .add:
      close()
      actions.add()
    case .release:
      guard let url = model.release?.pageURL else { return }
      close()
      actions.openReleasePage(url)
    case .login:
      login.toggle()
      model.login = AppMenuLoginRow(login)
    case .quit:
      close()
      actions.quit()
    }
  }

  /// A right-click or Control-click at `point` (window coordinates of the panel): over a tile it opens the tile's
  /// actions and is handled; elsewhere it is left to the panel.
  func secondaryClick(at point: NSPoint, in window: NSWindow) -> Bool {
    guard let slug = anchors.slug(at: point, in: window) else { return false }
    showActions(slug)
    return true
  }

  /// A tile's actions menu (click, right-click, Return), anchored at the tile; the tile stays selected while it is
  /// open. A clone being removed opens nothing.
  private func showActions(_ slug: String) {
    guard let tile = model.content.tiles.first(where: { $0.slug == slug }), !model.busy.isDeleting(slug) else { return }
    let target = AppTileMenuTarget { [weak self] command in self?.perform(command, slug: slug) }
    menuTarget = target
    model.menuTile = slug
    let menu = AppTileMenu.make(for: tile, target: target, busy: model.busy)
    presenter.present(menu, forTile: slug) { [weak self] in
      guard let self, self.model.menuTile == slug else { return }
      self.model.menuTile = nil
    }
  }

  func perform(_ command: AppTileCommand, slug: String) {
    guard let tile = model.content.tiles.first(where: { $0.slug == slug }) else { return }
    guard AppTileMenu.enabledCommands(for: tile, busy: model.busy).contains(command) else {
      log.error("Ignored \(command.rawValue, privacy: .public) for \(slug, privacy: .public)")
      return
    }
    close()
    model.menuTile = nil
    switch command {
    case .open: actions.open(slug: slug)
    case .update: actions.update(slug: slug)
    case .edit: actions.edit(slug: slug)
    case .reinstall: actions.reinstall(slug: slug)
    case .showInFinder: actions.showInFinder(slug: slug)
    case .delete: actions.delete(slug: slug)
    }
  }
}

/// Closures the SwiftUI views call.
struct AppMenuViewActions {
  let activate: @MainActor (AppMenuItem) -> Void
  /// VoiceOver custom actions of a tile run the menu commands directly.
  let perform: @MainActor (AppTileCommand, String) -> Void

  static let none = AppMenuViewActions(activate: { _ in }, perform: { _, _ in })
}
