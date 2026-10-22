import AppKit
import UI

@main
struct ClaudeMultiAccApp {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    // Never shown, but without it the windows get no ⌘C / ⌘V / ⌘Z / ⌘W / ⌘Q.
    AppMainMenu.install(in: app)
    let delegate = AppDelegate()
    app.delegate = delegate
    // NSApplication.delegate is weak; keep ours alive for the whole run loop.
    withExtendedLifetime(delegate) {
      app.run()
    }
  }
}
