import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Every error the new-instance sheet can show maps to a Russian sentence without English enum dumps (G16).
@Suite(.russian) struct UserMessageTests {
  static let errors: [any Error] = [
    InstallError.notVerified, InstallError.reportMismatch, InstallError.invalid([.duplicateSlug("work"), .badBadge("")]),
    InstallError.running("com.imaxzone.claude.work"), InstallError.launcherConfigMissing("/x/launcher.json"),
    InstallError.differentVolumes, InstallError.adhocBuild, InstallError.noPermanentIdentity,
    BuilderError.notAClone("x"), BuilderError.incompleteInstance("x"), BuilderError.vendorBundleId("x"),
    BuilderError.invalidDisplayName("x"), BuilderError.invalidPlist("x"), BuilderError.unexpectedBundleName("x"),
    BuilderError.forbiddenEntitlement("x"), BuilderError.targetRunning("com.x"), BuilderError.vendorUpdateActive,
    BuilderError.insufficientSpace(availableBytes: 1_000_000_000), BuilderError.unexpectedSourceBundleId("x"),
    BuilderError.unexpectedTeamId(expected: "A", found: "B"), BuilderError.sourceSignatureInvalid("x"),
    BuilderError.sourceUnreadable("x"), BuilderError.sourceChangedDuringCopy,
    BuilderError.commandFailed(tool: "codesign", exitCode: 1, stderr: "boom (\"x\")"), BuilderError.commandTimedOut("ditto"),
    BuilderError.launcherMissing("x"),
    BuilderError.noDesignatedRequirement, BuilderError.verificationFailed(["a"]), BuilderError.smokeFailed(["a"]),
    BuilderError.buildDirExists("x"), BuilderError.stagingPathRefused("x"),
    RebuildError.preflightFailed(["not-running"]), RebuildError.noPermanentIdentity, RebuildError.notVerified("x"),
    RebuildError.targetRunning("com.x"), RebuildError.backupInvalid("x"),
    RebuildError.afterSwap(step: "register", backup: "/b", message: "boom"),
    RebuildError.compensationFailed(original: "boom", leftAt: "/b/app"), RebuildError.afterRollback(message: "boom"),
    SwapError.compensationFailed(original: "boom", leftAt: "/b/app"),
    InstallError.afterMove(step: "store", message: "boom", restoredTo: "/s"),
    InstallError.compensationFailed(original: "boom", leftAt: "/Applications/x.app"),
    SwapError.liveMissing("x"), SwapError.stagedMissing("x"), SwapError.backupExists("x"), SwapError.differentVolumes("a", "b"),
    NewInstanceError.nameTooLong(41), NewInstanceError.storeCorrupt("/x"),
    SigningKeychainError.unquotable, SigningKeychainError.passwordMissing("/x/keychain-password"),
    SigningKeychainError.unlockFailed("unlock-keychain: returned -25293"),
    SigningKeychainError.commandFailed(step: "import", stderr: "boom (\"x\")"), SigningKeychainError.identityNotFound("/x"),
    SigningKeychainError.searchListChanged, SigningKeychainError.recordedIdentityMissing("AB"),
    SigningKeychainError.lockUnavailable, TranslocationError.originalUnknown,
    TranslocationError.foreignAppInTheWay("/Applications/ClaudeMultiAcc.app"),
    TranslocationError.newerCopyInstalled(installed: "1.10.0", running: "1.2.0"), SwapError.liveChanged("x"),
    ClonePathRefusal.foreignBundle(name: "Claude evil", path: "/Applications/Xcode.app"),
    ClonePathRefusal.bundleId(name: "Claude evil", bundleId: "com.apple.dt.Xcode"),
    ClonePathRefusal.changed(name: "Claude mv2", path: "~/Library/Application Support/ClaudeProfiles/mv2"),
    QuarantineError.removeFailed(path: "/x", errno: EPERM),
    CocoaError(.fileWriteNoPermission),
  ]

  @Test(arguments: 0..<errors.count)
  func mapsToARussianMessage(index: Int) {
    let message = UserMessage.text(for: Self.errors[index])
    #expect(!message.isEmpty)
    #expect(message.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil, "\(message)")
    for artifact in ["(", ")", "\"", "Error", "com.", "[", "]"] {
      #expect(!message.contains(artifact), "\(Self.errors[index]) → \(message)")
    }
  }

  @Test func englishDescriptionsStayForLogs() {
    #expect(InstallError.running("com.x").description == "com.x is running")
    #expect(RebuildError.targetRunning("com.x").description.contains("com.x is running"))
  }
}
