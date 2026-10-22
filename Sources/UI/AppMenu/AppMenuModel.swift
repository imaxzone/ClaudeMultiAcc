import AppKit
import Combine
import InstanceBuilder
import Support

/// The «Открывать при старте системы» row as last read from the switch; the wording and the switch position come
/// from `LaunchAtLoginPresentation`.
public struct AppMenuLoginRow: Equatable, Sendable {
  public let state: LaunchAtLoginState
  /// The last error, otherwise what the state needs explained (`LaunchAtLoginToggle.subtitle`).
  public let subtitle: String?
  /// The subtitle is an error (drawn red).
  public let isError: Bool

  public init(state: LaunchAtLoginState, subtitle: String? = nil, isError: Bool = false) {
    self.state = state
    self.subtitle = subtitle
    self.isError = isError
  }

  @MainActor
  public init(_ toggle: any LaunchAtLoginToggle) {
    self.init(state: toggle.state, subtitle: toggle.subtitle, isError: toggle.errorText != nil)
  }

  public var isOn: Bool { state.isOn }
  public var isEnabled: Bool { state.isAvailable }
}

/// The highlighted item and whether the keyboard put it there (only then a focus ring is drawn).
struct AppMenuHighlight: Equatable {
  let item: AppMenuItem
  let byKeyboard: Bool
}

/// What the open menu shows. `AppMenuController` fills it; the SwiftUI views only read it.
@MainActor
public final class AppMenuModel: ObservableObject {
  @Published public internal(set) var content: AppMenuContent = .empty
  @Published public internal(set) var release: AppReleaseInfo?
  @Published public internal(set) var login = AppMenuLoginRow(state: .off)
  /// Tile icons by slug; a missing entry draws the generic app icon.
  @Published public internal(set) var icons: [String: NSImage] = [:]
  @Published var highlight: AppMenuHighlight?
  /// The tile whose actions menu is open (drawn selected).
  @Published var menuTile: String?
  /// An update run and the clones being removed (`AppMenuController`'s `busy` source).
  @Published public internal(set) var busy: AppMenuBusy = .idle
  /// The Claude update check as the header shows it: a result already seen in an open panel reads as idle.
  @Published public internal(set) var claudeUpdate: ClaudeUpdateStatus = .idle
  /// The Claude the clones are built from (the newest source), for the header's idle line; nil when unknown.
  @Published public internal(set) var claudeVersion: String?

  public init() {}

  var layout: AppMenuLayout { AppMenuLayout(content: content, hasRelease: release != nil, busy: busy) }

  func isHighlighted(_ item: AppMenuItem) -> Bool { highlight?.item == item }
  func hasKeyboardFocus(_ item: AppMenuItem) -> Bool { highlight == AppMenuHighlight(item: item, byKeyboard: true) }

  /// Mouse tracking: entering highlights like a menu item; leaving clears a mouse highlight (not a keyboard one).
  func hover(_ item: AppMenuItem, inside: Bool) {
    if inside {
      if highlight?.item != item || highlight?.byKeyboard == true { highlight = AppMenuHighlight(item: item, byKeyboard: false) }
    } else if highlight == AppMenuHighlight(item: item, byKeyboard: false) {
      highlight = nil
    }
  }
}
