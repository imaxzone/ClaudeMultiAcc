import Foundation
import Support

/// Where the permanent signing identity comes from: `SigningIdentityProvisioner`, which the app runs on the first
/// «+ Добавить» and before every build (its own keychain; no Terminal, no password prompt).
public enum SigningSetup {
  /// English, for the CLI and logs.
  public static let hint = "open ClaudeMultiAcc and click + Add once: it creates the identity in its own keychain "
    + "and checks it again before every build"
  /// In the UI language, for the UI.
  public static var userHint: String { BuilderText.string("signing.user-hint") }
}

/// User-facing text for errors shown in the UI (G16), in the UI language. English `description`s stay for logs and
/// the CLI.
public enum UserMessage {
  static var fallback: String { BuilderText.string("error.unexpected") }

  public static func text(for error: any Error) -> String {
    switch error {
    case let error as NewInstanceError: error.message
    case let error as InstallError: error.userMessage
    case let error as BuilderError: error.userMessage
    case let error as RebuildError: error.userMessage
    case let error as SwapError: error.userMessage
    case let error as SigningKeychainError: error.userMessage
    case let error as TranslocationError: error.userMessage
    case let error as QuarantineError: error.userMessage
    case let error as ClonePathRefusal: error.userMessage
    default: fallback
    }
  }
}

extension InstallError {
  public var userMessage: String {
    switch self {
    case .notVerified: BuilderText.string("install.not-verified")
    case .reportMismatch: BuilderText.string("install.report-mismatch")
    case .invalid(let errors): errors.map(\.message).joined(separator: "; ")
    case .running: BuilderText.string("install.running")
    case .launcherConfigMissing: BuilderText.string("install.launcher-config-missing")
    case .differentVolumes: BuilderText.string("build.different-volumes")
    case .adhocBuild: BuilderText.string("install.adhoc")
    case .noPermanentIdentity: SigningSetup.userHint
    case .afterMove(let step, _, _): BuilderText.format("install.after-move", step)
    case .compensationFailed(_, let leftAt): BuilderText.format("install.compensation-failed", leftAt)
    }
  }
}

extension BuilderError {
  public var userMessage: String {
    switch self {
    case .notAClone, .incompleteInstance, .vendorBundleId, .invalidDisplayName:
      BuilderText.string("builder.invalid-instance")
    case .invalidPlist, .unexpectedBundleName: BuilderText.string("builder.invalid-plist")
    case .forbiddenEntitlement: BuilderText.string("builder.forbidden-entitlement")
    case .targetRunning: BuilderText.string("builder.target-running")
    case .vendorUpdateActive: BuilderText.string("builder.vendor-updating")
    case .insufficientSpace(let bytes):
      BuilderText.format("builder.insufficient-space", Localization.byteCount(bytes))
    case .unexpectedSourceBundleId, .unexpectedTeamId, .sourceSignatureInvalid:
      BuilderText.string("builder.source-signature")
    case .sourceUnreadable: BuilderText.string("builder.source-unreadable")
    case .sourceChangedDuringCopy: BuilderText.string("builder.source-changed")
    case .commandFailed(let tool, _, _): BuilderText.format("builder.command-failed", tool)
    case .commandTimedOut(let tool): BuilderText.format("builder.command-timed-out", tool)
    case .launcherMissing: BuilderText.string("builder.launcher-missing")
    case .noDesignatedRequirement: BuilderText.string("builder.no-requirement")
    case .verificationFailed: BuilderText.string("builder.verification-failed")
    case .smokeFailed: BuilderText.string("builder.smoke-failed")
    case .buildDirExists, .stagingPathRefused: BuilderText.string("builder.build-dir")
    }
  }
}

extension RebuildError {
  public var userMessage: String {
    switch self {
    case .preflightFailed(let ids): BuilderText.format("rebuild.preflight-failed", ids.count)
    case .noPermanentIdentity: SigningSetup.userHint
    case .notVerified: BuilderText.string("rebuild.not-verified")
    case .targetRunning: BuilderText.string("rebuild.target-running")
    case .runningDuringRollback(_, let backup): BuilderText.format("rebuild.running-during-rollback", backup)
    case .backupInvalid: BuilderText.string("rebuild.backup-invalid")
    case .afterSwap(let step, let backup, _): BuilderText.format("rebuild.after-swap", step, backup)
    case .compensationFailed(_, let leftAt): BuilderText.format("rebuild.compensation-failed", leftAt)
    case .afterRollback: BuilderText.string("rebuild.after-rollback")
    }
  }
}

extension SwapError {
  public var userMessage: String {
    switch self {
    case .liveMissing: BuilderText.string("swap.live-missing")
    case .stagedMissing: BuilderText.string("swap.staged-missing")
    case .backupExists: BuilderText.string("swap.backup-exists")
    case .differentVolumes: BuilderText.string("build.different-volumes")
    case .liveChanged: BuilderText.string("swap.live-changed")
    case .compensationFailed(_, let leftAt): BuilderText.format("swap.compensation-failed", leftAt)
    }
  }
}
