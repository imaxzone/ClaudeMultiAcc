import Foundation

public enum RebuildError: Error, Equatable, Sendable {
  case preflightFailed([String])
  case noPermanentIdentity
  case notVerified(String)
  case targetRunning(String)
  /// `rollback` refused because the app runs; the backup it was asked to restore.
  case runningDuringRollback(String, backup: String)
  case backupInvalid(String)
  /// The swap happened but a later step failed; the backup path is kept for `rollback`.
  case afterSwap(step: String, backup: String, message: String)
  /// An undo step failed as well; `leftAt` is where the bundle that was live is now.
  case compensationFailed(original: String, leftAt: String)
  /// The app was restored but `instances.json` could not be updated.
  case afterRollback(message: String)
}

extension RebuildError: CustomStringConvertible {
  /// English, for the CLI and logs.
  public var description: String {
    switch self {
    case .preflightFailed(let ids): "preflight failed: \(ids.joined(separator: ", "))"
    case .noPermanentIdentity: "no permanent signing identity (\(SigningSetup.hint))"
    case .notVerified(let why): "the build did not verify: \(why)"
    case .targetRunning(let id):
      "\(id) is running — nothing was replaced; quit it, then run `cmacc instance rebuild second --apply` again"
    case .runningDuringRollback(let id, let backup):
      "\(id) is running — nothing was restored; quit it, then run `cmacc instance rollback second \(backup)` again"
    case .backupInvalid(let path): "not a backup made by rebuild: \(path)"
    case .afterSwap(let step, let backup, let message):
      "swapped, then \(step) failed: \(message). To finish: quit Claude 2nd and run "
        + "`cmacc instance rollback second \(backup)` to restore the previous app, "
        + "then `cmacc instance rebuild second --apply` to rebuild again"
    case .compensationFailed(let original, let leftAt):
      "\(original); undoing it failed too — the app that was installed is now at \(leftAt); "
        + "move it back to /Applications/Claude 2nd.app by hand (see the RUNBOOK)"
    case .afterRollback(let message):
      "the backup was restored, but instances.json was not updated (\(message)); "
        + "set builtBy of second to \"legacy-script\" in instances.json once the file is readable"
    }
  }
}
