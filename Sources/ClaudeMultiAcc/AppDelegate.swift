import AppKit
import UI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var app: MenuBarApp?
  private var earlyURLs: [URL] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // A second copy (same bundle id, launched later) quits quietly and leaves its links to the older one.
    if SingleInstance.yieldToOlderCopy(forwarding: earlyURLs) {
      earlyURLs = []
      NSApp.terminate(nil)
      return
    }
    let app = MenuBarApp()
    app.start()
    self.app = app
    if !earlyURLs.isEmpty {
      app.handle(urls: earlyURLs)
      earlyURLs = []
    }
  }

  /// Quitting waits (bounded) for `claude://` to go back to the official Claude and for an update pass to end.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let app else { return .terminateNow }
    Task {
      await app.shutdown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// `claude://` links (only delivered here if LaunchServices routes the scheme to us).
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let app else {
      earlyURLs.append(contentsOf: urls)
      return
    }
    app.handle(urls: urls)
  }
}
