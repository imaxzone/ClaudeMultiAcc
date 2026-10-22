import AppKit
import InstanceBuilder
import Support
import SwiftUI

/// The new menu on invented data (`cmacc ui snapshot`): the official Claude and three clones, two of them behind
/// the official 3.1700.0, a CLI-only account that the menu hides, and a newer ClaudeMultiAcc release.
@MainActor
enum AppMenuDemo {
  static let officialVersion = "3.1700.0"
  /// The Claude the update check finds and downloads in the header shots.
  static let newerClaude = "3.1800.0"
  static let release = AppReleaseInfo(
    version: "1.4.0", pageURL: URL(string: "https://github.com/example/ClaudeMultiAcc/releases/latest")
      ?? URL(fileURLWithPath: "/"))

  /// Built on each use: the invented «Claude 5x акк» is named in the current language.
  static var instances: [Instance] {
    [
      app("main", "Claude", kind: .official, badge: nil),
      app("second", "Claude 2nd", badge: "2nd"),
      app("fivex", UIText.string("demo.fivex"), badge: "5x"),
      app("alt", "Claude (alt CLI)", kind: .cliOnly, badge: nil),
      app("mv2", "Claude mv2", badge: "mv2"),
    ].compactMap { $0 }
  }

  /// Installed versions by slug: 2nd and mv2 are behind.
  static let versions = ["main": officialVersion, "second": "3.1623.0", "fivex": officialVersion, "mv2": "3.1623.0"]

  /// A controller filled the way an open fills it (`prepareToOpen`), never shown on screen. `claude` is the Claude
  /// update check's status; `newestClaude` a downloaded Claude newer than the official app (nil: none).
  static func controller(
    instances: [Instance] = instances, versions: [String: String] = versions, release: AppReleaseInfo? = release,
    login: LaunchAtLoginState = .off, loginError: String? = nil, busy: AppMenuBusy = .idle,
    claude: ClaudeUpdateStatus = .idle, newestClaude: String? = nil
  ) -> AppMenuController {
    let byPath = instances.reduce(into: [String: String]()) { result, instance in
      if let path = instance.appPath, let version = versions[instance.slug.raw] { result[path] = version }
    }
    let controller = AppMenuController(
      instances: { instances }, login: DemoLaunchAtLogin(login, errorText: loginError), actions: DemoMenuActions(),
      releaseInfo: { release }, busy: { busy }, claudeUpdate: { claude }, newestClaude: { newestClaude },
      versions: DemoAppVersions(byPath: byPath),
      icons: DemoAppIcons(instances: instances), presenter: nil)
    controller.prepareToOpen()
    return controller
  }

  /// Every literal here matches the slug pattern, so this never returns nil in practice.
  static func demoSlug(_ raw: String) -> Slug? {
    try? Slug(raw)
  }

  private static func app(_ raw: String, _ name: String, kind: InstanceKind = .clone, badge: String?) -> Instance? {
    demoSlug(raw).map { slug in
      Instance(
        slug: slug, name: name, kind: kind, bundleId: kind == .cliOnly ? nil : "com.example.claude.\(raw)",
        appPath: kind == .cliOnly ? nil : "/Applications/\(name).app", badge: badge,
        builtBy: kind == .clone ? "cmacc" : nil)
    }
  }
}

/// The menu as it looks open: the panel shape on the window background (materials do not render offscreen).
struct AppMenuSnapshotPanel: View {
  @ObservedObject var model: AppMenuModel
  let anchors: AppMenuAnchors?

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: AppMenuStyle.cornerRadius, style: .continuous)
    AppMenuView(model: model, anchors: anchors, actions: .none)
      .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
      .overlay(shape.strokeBorder(Color(nsColor: AppMenuStyle.panelEdge), lineWidth: 0.5))
  }
}

/// The demo icon with each clone's badge baked in, as the clone's own `.icns` would carry it.
@MainActor
final class DemoAppIcons: AppIconLoading {
  private var badges: [String: String?] = [:]
  private var cache: [String: NSImage] = [:]

  init(instances: [Instance]) {
    for instance in instances {
      if let path = instance.appPath { badges[path] = instance.kind == .official ? nil : instance.badge }
    }
  }

  func icon(for source: AppTileIconSource) -> NSImage? {
    switch source {
    case .none: return nil
    case .workspace(let path), .bundleIcns(let path):
      guard let badge = badges[path] else { return nil }
      if let image = cache[path] { return image }
      let image = DemoIcon.image(badge: badge)
      cache[path] = image
      return image
    }
  }
}

struct DemoAppVersions: AppVersionReading {
  let byPath: [String: String]
  func version(appPath: String) -> String? { byPath[appPath] }
}

@MainActor
final class DemoLaunchAtLogin: LaunchAtLoginToggle {
  let state: LaunchAtLoginState
  let errorText: String?

  init(_ state: LaunchAtLoginState, errorText: String? = nil) {
    self.state = state
    self.errorText = errorText
  }

  func refresh() {}
  func toggle() {}
}

/// Snapshots never act.
@MainActor
final class DemoMenuActions: AppMenuActions {
  func open(slug: String) {}
  func updateAll() {}
  func update(slug: String) {}
  func edit(slug: String) {}
  func reinstall(slug: String) {}
  func showInFinder(slug: String) {}
  func delete(slug: String) {}
  func add() {}
  func openReleasePage(_ url: URL) {}
  func checkClaudeUpdates() {}
  func quit() {}
}
