import AppKit
import InstanceBuilder

/// The restart confirmation and the problem report as `NSAlert`s.
@MainActor
public final class AlertUpdateDialogs: UpdateDialogs {
  public init() {}

  public func confirmRestart(names: [String]) async -> UpdateRestartAnswer {
    let alert = Self.confirmation(names: names)
    guard await ModalAlert.run(alert) == .alertFirstButtonReturn else { return .cancel }
    return .restart(dontAskAgain: alert.suppressionButton?.state == .on)
  }

  public func report(problems: [String]) async {
    _ = await ModalAlert.run(Self.problemReport(problems))
  }

  /// «Перезапустить» (default), «Отмена» and «Больше не спрашивать»; unsaved text may be lost, hence the warning.
  static func confirmation(names: [String]) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = UpdateFlowText.confirmTitle(names: names)
    alert.informativeText = UpdateFlowText.confirmText(names: names)
    alert.addButton(withTitle: UpdateFlowText.restartButton)
    alert.addButton(withTitle: UpdateFlowText.cancelButton)
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = UpdateFlowText.dontAskAgain
    return alert
  }

  static func problemReport(_ problems: [String]) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = UpdateFlowText.reportTitle
    alert.informativeText = problems.joined(separator: "\n")
    return alert
  }
}

/// Wording of the update flow, in the UI language.
enum UpdateFlowText {
  static var restartButton: String { UIText.string("update.restart") }
  static var cancelButton: String { UIText.string("common.cancel") }
  static var dontAskAgain: String { UIText.string("update.dont-ask") }
  static var reportTitle: String { UIText.string("update.report-title") }
  static var busy: String { UIText.string("update.busy") }
  static var registryUnreadable: String { UIText.string("update.registry-unreadable") }

  static func confirmTitle(names: [String]) -> String {
    guard names.count > 1 else { return UIText.format("update.confirm-title.one", list(names)) }
    return UIText.format("update.confirm-title.many", names.count)
  }

  static func confirmText(names: [String]) -> String {
    guard names.count > 1 else { return UIText.string("update.confirm-text.one") }
    return UIText.format("update.confirm-text.many", list(names))
  }

  static func signingFailed(_ detail: String) -> String {
    UIText.format("update.signing-failed", detail)
  }

  /// A line for a pass that did not run for any clone; nil when it did.
  static func passProblem(_ decision: UpdateDecision) -> String? {
    switch decision.action {
    case .skippedLocked, .coalesced: busy
    case .fail: UIText.format("update.pass-failed", CloneRestarter.shortDetail(decision.detail))
    default: nil
    }
  }

  /// A line for a chosen clone the update pass could not build; nil when nothing went wrong.
  static func problem(_ decision: UpdateDecision, name: String) -> String? {
    switch decision.action {
    case .fail: UIText.format("update.problem.build-failed", name, CloneRestarter.shortDetail(decision.detail))
    case .needsIdentity: UIText.format("update.problem.needs-identity", name)
    case .retry: UIText.format("update.problem.retry", name)
    case .skip where decision.detail == UpdateDecision.autoRebuildOff:
      UIText.format("update.problem.auto-rebuild-off", name)
    default: nil
    }
  }

  static func list(_ names: [String]) -> String { names.joined(separator: ", ") }
}
