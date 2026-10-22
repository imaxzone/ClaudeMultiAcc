import Foundation

extension LaunchAtLoginState {
  /// Where the switch knob sits: the old LaunchAgent also starts the app at login, so it reads as on.
  public var isOn: Bool { self == .on || self == .legacyAgent }

  /// False only outside `/Applications` and `~/Applications`, where the switch is greyed out.
  public var isAvailable: Bool { self != .unavailable }

  /// The grey line under the switch, or nil when the switch says it all.
  public var subtitle: String? {
    switch self {
    case .on, .off: nil
    case .needsApproval: LaunchAtLoginText.needsApproval
    case .legacyAgent: LaunchAtLoginText.legacyAgent
    case .unavailable: LaunchAtLoginText.unavailable
    }
  }
}

extension LaunchAtLoginToggle {
  /// The row's subtitle: the last error first, otherwise what the state needs explained.
  public var subtitle: String? { errorText ?? state.subtitle }
}

/// Wording of the «Открывать при старте системы» switch, in the UI language.
enum LaunchAtLoginText {
  static var needsApproval: String { UIText.string("login.needs-approval") }
  static var legacyAgent: String { UIText.string("login.legacy-agent") }
  static var unavailable: String { UIText.string("login.unavailable") }
  static var turnOnFailed: String { UIText.string("login.turn-on-failed") }
  static var turnOffFailed: String { UIText.string("login.turn-off-failed") }
  static func legacyTrashFailed(_ detail: String) -> String { UIText.format("login.legacy-trash-failed", detail) }
}
