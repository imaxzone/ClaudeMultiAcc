import AppKit
import InstanceBuilder
import os
import Support

/// At startup, an app opened straight from a download (App Translocation), the Downloads folder, the Desktop or the
/// disk image offers to move itself to Applications: clones are built from there, and «Открывать при старте системы»
/// only works there. A build anywhere else (a developer's `dist/`) is left alone, and so is a copy whose offer was
/// declined before.
@MainActor
enum MoveToApplications {
  enum Outcome: Equatable {
    case stay
    /// The copy in Applications is about to relaunch: the caller quits.
    case relaunching
    /// «Не сейчас» for this copy: remember the path.
    case declined(String)
  }

  private static let log = AppLog.logger("relocate")

  static func shouldOffer(_ location: AppLocation, bundle: URL, home: URL, declinedPath: String? = nil) -> Bool {
    let path = bundle.standardizedFileURL.path
    if path == declinedPath { return false }
    switch location {
    case .applications: return false
    case .translocated: return true
    case .elsewhere:
      let places = ["Downloads", "Desktop"].map { home.appendingPathComponent($0).standardizedFileURL.path + "/" }
      return places.contains { path.hasPrefix($0) } || path.hasPrefix("/Volumes/")
    }
  }

  static func offerIfNeeded(home: URL, declinedPath: String?) -> Outcome {
    let bundle = Bundle.main.bundleURL
    let location = TranslocationCheck.liveLocation(of: bundle, home: home)
    guard shouldOffer(location, bundle: bundle, home: home, declinedPath: declinedPath) else { return .stay }
    NSApp.activate()
    guard confirmation().runModal() == .alertFirstButtonReturn else {
      return .declined(bundle.standardizedFileURL.path)
    }
    do {
      return try ApplicationsMover(home: home).moveAndRelaunch(running: bundle) != nil ? .relaunching : .stay
    } catch {
      log.error("Cannot move to Applications: \(String(describing: error), privacy: .public)")
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = MoveToApplicationsText.failedTitle
      alert.informativeText = error is CocoaError ? error.localizedDescription : UserMessage.text(for: error)
      alert.runModal()
      return .stay
    }
  }

  private static func confirmation() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = MoveToApplicationsText.title
    alert.informativeText = MoveToApplicationsText.text
    alert.addButton(withTitle: MoveToApplicationsText.move)
    alert.addButton(withTitle: MoveToApplicationsText.notNow)
    return alert
  }
}

/// Wording of the offer, in the UI language.
enum MoveToApplicationsText {
  static var title: String { UIText.string("move.title") }
  static var text: String { UIText.string("move.text") }
  static var move: String { UIText.string("move.move") }
  static var notNow: String { UIText.string("move.not-now") }
  static var failedTitle: String { UIText.string("move.failed") }
}
