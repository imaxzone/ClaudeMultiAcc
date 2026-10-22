import Foundation

/// What the «Открывать при старте системы» switch shows.
public enum LaunchAtLoginState: Equatable, Sendable {
  case on, off
  /// Registered, but the user must allow it in System Settings → Login Items.
  case needsApproval
  /// An old `cmacc agent install --kind app` LaunchAgent starts the app instead.
  case legacyAgent
  /// Not installed in /Applications or ~/Applications, so registering would record the wrong copy.
  case unavailable
}

/// The switch above «Выйти»; the menu reads `state` on every open and calls `toggle()` on click.
@MainActor public protocol LaunchAtLoginToggle: AnyObject {
  var state: LaunchAtLoginState { get }
  /// User-facing error from the last toggle, if any.
  var errorText: String? { get }
  func refresh()
  func toggle()
}
