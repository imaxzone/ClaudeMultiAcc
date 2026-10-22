import Foundation
import InstanceBuilder
import Support

/// The words of the Claude update check, in the UI language: the status line next to the menu's ↻ button, the
/// button's tooltip and VoiceOver label, and the alert the app shows after a failed manual check.
public enum ClaudeUpdateText {
  /// «Проверить обновления Claude»: the ↻ button's tooltip and VoiceOver label.
  public static var buttonLabel: String { UIText.string("claude.check") }

  /// The header line for `status`. `current` is the Claude the clones are built from, shown while idle; nil when
  /// idle and no Claude is known (the header then shows only the button).
  public static func line(_ status: ClaudeUpdateStatus, current: String?) -> String? {
    switch status {
    case .idle:
      guard let current, !current.isEmpty else { return nil }
      return UIText.format("claude.idle", current)
    case .checking:
      return UIText.string("claude.checking")
    case .downloading(let version, let percent):
      return UIText.format("claude.downloading", version, min(max(percent, 0), 100))
    case .verifying(let version):
      return UIText.format("claude.verifying", version)
    case .upToDate(let version):
      return UIText.format("claude.up-to-date", version)
    case .ready(let version):
      return UIText.format("claude.ready", version)
    case .failed:
      return UIText.string("claude.failed")
    }
  }

  /// «Не удалось обновить Claude» and one sentence on what went wrong and what to do; the details are in the log.
  public static func failureAlert(_ failure: ClaudeUpdateFailure) -> (title: String, message: String) {
    (UIText.string("claude.alert.title"), message(for: failure))
  }

  static func message(for failure: ClaudeUpdateFailure) -> String {
    switch failure {
    case .officialMissing:
      UIText.string("claude.alert.official-missing")
    case .network:
      UIText.string("claude.alert.network")
    case .badAnswer:
      UIText.string("claude.alert.bad-answer")
    case .untrustedURL:
      UIText.string("claude.alert.untrusted-url")
    case .notEnoughSpace(let free, let needed):
      UIText.format("claude.alert.no-space", Localization.byteCount(needed), Localization.byteCount(free))
    case .sizeMismatch, .checksumMismatch:
      UIText.string("claude.alert.damaged")
    case .unpackFailed:
      UIText.string("claude.alert.unpack-failed")
    case .notGenuine:
      UIText.string("claude.alert.not-genuine")
    case .versionMismatch(let expected, let found):
      UIText.format("claude.alert.version-mismatch", found, expected)
    case .busy:
      UIText.string("claude.alert.busy")
    case .storage:
      UIText.string("claude.alert.storage")
    }
  }
}
