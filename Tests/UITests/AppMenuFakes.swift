import AppKit
import Foundation
import InstanceBuilder
import Support
@testable import UI

/// A login switch whose state the test sets; `toggle()` flips on/off.
@MainActor
final class FakeLaunchAtLogin: LaunchAtLoginToggle {
  var state: LaunchAtLoginState
  var errorText: String?
  private(set) var refreshCount = 0
  private(set) var toggleCount = 0

  init(_ state: LaunchAtLoginState = .off, errorText: String? = nil) {
    self.state = state
    self.errorText = errorText
  }

  func refresh() { refreshCount += 1 }

  func toggle() {
    toggleCount += 1
    state = state == .on ? .off : .on
  }
}

/// Records every action as a short string («edit:mv2»).
@MainActor
final class RecordingMenuActions: AppMenuActions {
  private(set) var calls: [String] = []

  func open(slug: String) { calls.append("open:\(slug)") }
  func updateAll() { calls.append("updateAll") }
  func update(slug: String) { calls.append("update:\(slug)") }
  func edit(slug: String) { calls.append("edit:\(slug)") }
  func reinstall(slug: String) { calls.append("reinstall:\(slug)") }
  func showInFinder(slug: String) { calls.append("finder:\(slug)") }
  func delete(slug: String) { calls.append("delete:\(slug)") }
  func add() { calls.append("add") }
  func openReleasePage(_ url: URL) { calls.append("release:\(url.absoluteString)") }
  func checkClaudeUpdates() { calls.append("checkClaude") }
  func quit() { calls.append("quit") }
}

/// The Claude update check as the app reports it: its status and the newest Claude ClaudeMultiAcc builds from
/// (nil: no download newer than the official app). The test changes both between reads.
@MainActor
final class FakeClaudeUpdate {
  var status = ClaudeUpdateStatus.idle
  var newest: String?
}

/// Installed versions by app path.
struct FakeVersions: AppVersionReading {
  let byPath: [String: String]
  func version(appPath: String) -> String? { byPath[appPath] }
}

/// A distinct image per app path; none for paths it does not know.
@MainActor
final class FakeIcons: AppIconLoading {
  private(set) var requests: [AppTileIconSource] = []
  private var images: [String: NSImage] = [:]

  func icon(for source: AppTileIconSource) -> NSImage? {
    requests.append(source)
    switch source {
    case .workspace(let path), .bundleIcns(let path):
      if let image = images[path] { return image }
      let image = NSImage(size: NSSize(width: 8, height: 8))
      images[path] = image
      return image
    case .none:
      return nil
    }
  }
}

/// Keeps the last presented menu instead of showing it; `finish()` plays the menu closing.
@MainActor
final class FakeTileMenuPresenter: AppTileMenuPresenting {
  private(set) var menu: NSMenu?
  private(set) var slug: String?
  private var completion: (@MainActor () -> Void)?

  func present(_ menu: NSMenu, forTile slug: String, completion: @escaping @MainActor () -> Void) {
    self.menu = menu
    self.slug = slug
    self.completion = completion
  }

  func finish() {
    completion?()
    completion = nil
  }

  var titles: [String] { menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? [] }

  /// Chooses the item titled `title`, as a click would.
  func choose(_ title: String) {
    guard let menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
    menu.performActionForItem(at: index)
    finish()
  }
}

/// The owner's apps as `AppMenuContentTests` lists them, with versions keyed by app path.
@MainActor
struct AppMenuFixture {
  var instances = AppMenuContentTests.instances
  let login = FakeLaunchAtLogin()
  let actions = RecordingMenuActions()
  let icons = FakeIcons()
  let presenter = FakeTileMenuPresenter()
  let busy = FakeBusy()
  let claude = FakeClaudeUpdate()
  var release: AppReleaseInfo?
  /// Installed versions by app path (the owner's list: 2nd and mv2 behind the official 3.1700.0).
  var installed = AppMenuFixture.versions

  static let releaseURL = URL(string: "https://github.com/example/ClaudeMultiAcc/releases/tag/v1.4.0")!

  static var versions: FakeVersions {
    let paths = AppMenuContentTests.instances.reduce(into: [String: String]()) { result, instance in
      if let path = instance.appPath, let version = AppMenuContentTests.versions[instance.slug.raw] {
        result[path] = version
      }
    }
    return FakeVersions(byPath: paths)
  }

  func controller() -> AppMenuController {
    let instances = self.instances
    let release = self.release
    let busy = self.busy
    let claude = self.claude
    return AppMenuController(
      instances: { instances }, login: login, actions: actions, releaseInfo: { release }, busy: { busy.state },
      claudeUpdate: { claude.status }, newestClaude: { claude.newest }, versions: installed, icons: icons,
      presenter: presenter)
  }
}
