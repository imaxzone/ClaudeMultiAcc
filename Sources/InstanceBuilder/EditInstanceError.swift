import Foundation
import Support

/// Why an instance cannot be edited in the «Изменить…» window.
public enum EditRefusal: Sendable, Equatable {
  /// The vendor's Claude.
  case official
  /// A CLI-only account without an app.
  case noApp
  /// A clone built by the legacy script (only its own rebuild path may touch it).
  case legacy
  /// The entry lacks a bundle id, app path or profile.
  case incomplete
}

/// Why «Сохранить» did not apply the change. Nothing was changed, except where `compensationFailed` says otherwise.
public enum EditInstanceError: Error, Equatable, Sendable {
  case storeUnreadable(String)
  case notFound(String)
  case notEditable(name: String, reason: EditRefusal)
  case invalid([InstanceDraftProblem])
  case nothingToChange
  /// `<new name>.app` already exists next to the app.
  case targetExists(String)
  /// Ad hoc builds are test builds only.
  case adhocIdentity
  case notVerified(step: String?)
  /// An update pass held `update.lock` for too long.
  case busy
  /// The running clone did not quit within 30 s; its name.
  case stillRunning(String)
  /// A step after the build failed and was undone.
  case installFailed(step: String, message: String)
  /// A step failed and undoing it failed too; `leftAt` needs a look by hand.
  case compensationFailed(step: String, leftAt: String)
  /// `ClonePathPolicy` does not accept the app the entry names, or it was swapped after the check.
  case unsafePath(ClonePathRefusal)

  /// The window's text in the UI language (no paths except where the user must act, no raw error text).
  public var userMessage: String {
    switch self {
    case .storeUnreadable: BuilderText.string("store.unreadable")
    case .notFound: BuilderText.string("edit.not-found")
    case .notEditable(let name, let reason): Self.refusalMessage(name, reason)
    case .invalid(let problems): problems.map(\.message).joined(separator: "; ")
    case .nothingToChange: BuilderText.string("edit.nothing-to-change")
    case .targetExists(let path): BuilderText.format("edit.target-exists", (path as NSString).lastPathComponent)
    case .adhocIdentity: BuilderText.string("edit.adhoc")
    case .notVerified(let step):
      step.map { BuilderText.format("edit.not-verified-at", $0) } ?? BuilderText.string("edit.not-verified")
    case .busy: BuilderText.string("edit.busy")
    case .stillRunning(let name): BuilderText.format("edit.still-running", name)
    case .installFailed: BuilderText.string("edit.install-failed")
    case .compensationFailed(_, let leftAt): BuilderText.format("edit.compensation-failed", leftAt)
    case .unsafePath(let refusal): refusal.userMessage
    }
  }

  private static func refusalMessage(_ name: String, _ reason: EditRefusal) -> String {
    switch reason {
    case .official: BuilderText.string("edit.refused.official")
    case .noApp: BuilderText.format("edit.refused.no-app", name)
    case .legacy: BuilderText.format("edit.refused.legacy", name)
    case .incomplete: BuilderText.format("edit.refused.incomplete", name)
    }
  }
}

extension EditInstanceError: CustomStringConvertible {
  /// English, for logs.
  public var description: String {
    switch self {
    case .storeUnreadable(let detail): "cannot read instances.json: \(detail)"
    case .notFound(let slug): "no instance '\(slug)'"
    case .notEditable(let name, let reason): "'\(name)' cannot be edited (\(reason))"
    case .invalid(let problems): "invalid change: " + problems.map(\.description).joined(separator: "; ")
    case .nothingToChange: "name and badge are unchanged"
    case .targetExists(let path): "\(path) already exists"
    case .adhocIdentity: "ad hoc builds cannot be installed"
    case .notVerified(let step): "the build did not verify (step \(step ?? "?"))"
    case .busy: "update.lock is held by an update pass"
    case .stillRunning(let name): "'\(name)' did not quit in \(EditInstance.quitTimeout.components.seconds) s"
    case .installFailed(let step, let message): "\(step) failed (\(message)); undone"
    case .compensationFailed(let step, let leftAt): "\(step) failed and could not be undone; check \(leftAt)"
    case .unsafePath(let refusal): "refused by the path policy: \(refusal)"
    }
  }
}
