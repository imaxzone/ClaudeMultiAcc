import AppKit
import InstanceBuilder
import os
import Support

/// What the menu's commands do in the live app.
@MainActor
final class AppActions: AppMenuActions {
  /// The clones behind the official app, in grid order (the menu's banner).
  var behindSlugs: @MainActor () -> [String] = { [] }

  private let list: InstanceList
  private let updates: UpdateFlow
  private let editor: InstanceEditorWindowController
  private let remove: @MainActor (String) -> Void
  private let checkClaude: @MainActor () -> Void
  private let opener: any AppOpening
  private let log = AppLog.logger("app-actions")

  /// - Parameters:
  ///   - checkClaude: the menu's ↻, one manual Claude update check (the app shows an alert if it fails).
  ///   - opener: launches an app or brings it to the front (default: `NSWorkspace`, as a Dock click).
  init(
    list: InstanceList, updates: UpdateFlow, editor: InstanceEditorWindowController,
    remove: @escaping @MainActor (String) -> Void, checkClaude: @escaping @MainActor () -> Void = {},
    opener: any AppOpening = ForegroundAppOpener()
  ) {
    self.list = list
    self.updates = updates
    self.editor = editor
    self.remove = remove
    self.checkClaude = checkClaude
    self.opener = opener
  }

  func open(slug: String) { Self.openApp(slug: slug, in: list.instances, opener: opener) }
  func updateAll() { updates.update(slugs: behindSlugs()) }
  func update(slug: String) { updates.update(slugs: [slug]) }
  func edit(slug: String) { editor.showEdit(slug: slug) }
  /// The editor offers «Переустановить» when nothing is changed there.
  func reinstall(slug: String) { editor.showEdit(slug: slug) }
  func add() { editor.showAdd() }
  func delete(slug: String) { remove(slug) }

  func showInFinder(slug: String) {
    guard let path = list.instance(slug: slug)?.appPath else {
      log.error("No app to show for \(slug, privacy: .public)")
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  func openReleasePage(_ url: URL) { NSWorkspace.shared.open(url) }
  func checkClaudeUpdates() { checkClaude() }
  func quit() { NSApp.terminate(nil) }

  /// Opens the app of `slug` in `instances`. No instance, no app path, or a launch that fails: logged, nothing shown.
  /// Returns the launch (nil when there is nothing to open).
  @discardableResult
  static func openApp(slug: String, in instances: [Instance], opener: any AppOpening) -> Task<Void, Never>? {
    let log = AppLog.logger("app-actions")
    guard let path = instances.first(where: { $0.slug.raw == slug })?.appPath, !path.isEmpty else {
      log.error("No app to open for \(slug, privacy: .public)")
      return nil
    }
    let app = URL(fileURLWithPath: path)
    return Task {
      do {
        try await opener.open(app: app)
      } catch {
        log.error("Cannot open \(app.path, privacy: .public): \(String(describing: error), privacy: .public)")
      }
    }
  }
}

/// `NSWorkspace.openApplication(at:configuration:)` in the foreground: launches the app, or brings it to the front
/// when it already runs (a clone through its launcher, as Finder opens it).
struct ForegroundAppOpener: AppOpening {
  func open(app: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
  }
}
