import AppKit

/// Runs an alert's modal loop from a plain main run-loop callback, never from inside the calling main-actor job:
/// a modal loop entered inside a job runs no other main-actor work (the main queue is not drained re-entrantly),
/// so the menu, the sign-in router and the instance list would stall while the alert is open. The caller just waits.
@MainActor
enum ModalAlert {
  static func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
    await withCheckedContinuation { continuation in
      RunLoop.main.perform(inModes: [.common, .modalPanel]) {
        MainActor.assumeIsolated {
          NSApp.activate()
          continuation.resume(returning: alert.runModal())
        }
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }
}
