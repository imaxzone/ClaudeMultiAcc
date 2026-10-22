import AppKit
import InstanceBuilder
import SwiftUI

/// The question as an `NSAlert` with the clone's own icon and the options as its accessory view; problems as a
/// plain alert. «Удалить» is red and has no Return shortcut (Escape cancels).
@MainActor
public final class AlertDeleteDialogs: DeleteDialogs {
  /// Shows a ready alert and returns the button pressed: `runModal()` on the real machine.
  typealias Presenter = @MainActor (NSAlert) -> NSApplication.ModalResponse

  /// Sizes at least as wide as any real one, so the layout made before they arrive never needs to reflow.
  static let widestBytes: Int64 = 999_990_000_000

  private let present: Presenter
  private let icon: @MainActor (URL) -> NSImage

  public convenience init() {
    self.init(
      present: { alert in
        NSApp.activate()
        return alert.runModal()
      },
      icon: { NSWorkspace.shared.icon(forFile: $0.path) })
  }

  init(present: @escaping Presenter, icon: @escaping @MainActor (URL) -> NSImage) {
    self.present = present
    self.icon = icon
  }

  public func ask(_ model: DeleteDialogModel) async -> RemovalMode? {
    let alert = Self.makeAlert(for: model, icon: icon(model.target.app))
    let response = await presentFromRunLoop(alert)
    return response == .alertFirstButtonReturn ? model.choice : nil
  }

  public func showProblems(title: String, lines: [String]) async {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = lines.joined(separator: "\n\n")
    alert.addButton(withTitle: DeleteDialogText.okButton)
    _ = await presentFromRunLoop(alert)
  }

  /// Presents `alert` from a plain main run loop callback, never from inside the calling main-actor job: a modal
  /// loop entered inside a job runs no other main-actor work (the main queue is not drained re-entrantly), so the
  /// sizes measured meanwhile would never reach the open alert. The calling job just waits, leaving the main actor
  /// free.
  private func presentFromRunLoop(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    let present = present
    let show: @MainActor () -> NSApplication.ModalResponse = { present(alert) }
    return await withCheckedContinuation { continuation in
      RunLoop.main.perform(inModes: [.common, .modalPanel]) {
        MainActor.assumeIsolated { continuation.resume(returning: show()) }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }

  /// The question with the clone's own `icon`. «Удалить» is the first (rightmost) button, so
  /// `.alertFirstButtonReturn` means delete.
  static func makeAlert(for model: DeleteDialogModel, icon: NSImage) -> NSAlert {
    let text = model.text
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.icon = icon
    alert.messageText = text.title
    alert.informativeText = text.lead
    alert.accessoryView = accessoryView(for: model)
    let delete = alert.addButton(withTitle: DeleteDialogText.deleteButton)
    delete.hasDestructiveAction = true
    delete.keyEquivalent = ""
    alert.addButton(withTitle: DeleteDialogText.cancelButton).keyEquivalent = "\u{1b}"
    return alert
  }

  /// The options view, as tall as it would be with the widest sizes and top-aligned in that frame.
  static func accessoryView(for model: DeleteDialogModel) -> NSView {
    let widest = DeleteDialogModel(target: model.target)
    widest.appOnlyBytes = widestBytes
    widest.profileBytes = widestBytes
    let height = ceil(NSHostingView(rootView: DeleteDialogView(model: widest)).fittingSize.height)
    let hosting = NSHostingView(rootView: DeleteDialogView(model: model).frame(height: height, alignment: .top))
    hosting.frame = NSRect(x: 0, y: 0, width: DeleteDialogView.width, height: height)
    return hosting
  }
}
