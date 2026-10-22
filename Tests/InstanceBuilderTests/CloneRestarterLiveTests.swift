import Foundation
import Testing
@testable import InstanceBuilder

/// The live quitter asks only clones to quit. Only its pure gate is tested: `requestQuit` itself would talk to running
/// apps, which tests never do.
@Suite struct WorkspaceQuitterTests {
  @Test(arguments: ["com.apple.dt.Xcode", CloneSpec.vendorBundleId, "com.imaxzone.ClaudeMultiAcc", "com.apple.finder",
                    "com.imaxzone.claude.", "com.imaxzone.claude.Not A Slug", "com.anthropic.claudefordesktop3", ""])
  func refusesEveryAppThatIsNotAClone(bundleId: String) {
    #expect(!WorkspaceQuitter.mayQuit(bundleId: bundleId))
  }

  @Test(arguments: ["com.imaxzone.claude.mv2", "com.imaxzone.claude.5x-akk", CloneSpec.legacySecondBundleId])
  func clonesMayBeAskedToQuit(bundleId: String) {
    #expect(WorkspaceQuitter.mayQuit(bundleId: bundleId))
  }
}
