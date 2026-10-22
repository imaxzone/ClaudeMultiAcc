import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Positive validation of the paths `instances.json` names before anything is moved, swapped, trashed or quit.
@Suite(.russian) struct ClonePathPolicyTests {
  @Test func aRealCloneAndItsProfilePass() throws {
    let f = try PolicyFixture()
    let app = try f.policy.checkApp(f.clone())
    #expect(app.url.path == f.userApps.appendingPathComponent("Claude mv2.app").path)
    #expect(app.identity != nil && app.state() == .unchanged)
    let profile = try #require(try f.policy.checkProfile(f.clone()))
    #expect(profile.url.path == f.profiles.appendingPathComponent("mv2").path)
    #expect(profile.identity != nil && profile.state() == .unchanged)
  }

  @Test func anAppAndProfileNotOnDiskPassWithNothingToMove() throws {
    let f = try PolicyFixture()
    let app = try f.policy.checkApp(f.clone("fresh"))
    #expect(app.identity == nil && app.state() == .gone)
    let profile = try #require(try f.policy.checkProfile(f.clone("fresh")))
    #expect(profile.identity == nil && profile.state() == .gone)
    let noProfile = Instance(slug: testSlug("fresh"), name: "Claude fresh", kind: .clone,
                             bundleId: "com.imaxzone.claude.fresh", appPath: f.userApps.appendingPathComponent("F.app").path)
    #expect(try f.policy.checkProfile(noProfile) == nil)
  }

  /// The legacy `second`: its id lives in the vendor namespace; a legacy-script build has no `ClaudeMultiAccSlug`.
  @Test func theLegacySecondPassesWithOrWithoutTheSlugKey() throws {
    let f = try PolicyFixture()
    let legacyId = CloneSpec.legacySecondBundleId
    let app = f.userApps.appendingPathComponent("Claude second.app")
    try PolicyFixture.writeApp(app, ["CFBundleIdentifier": legacyId])
    #expect(f.refusal { try f.policy.checkApp(f.clone("second", bundleId: legacyId, builtBy: "legacy-script")) } == nil)
    #expect(f.refusal { try f.policy.checkApp(f.clone("second", bundleId: legacyId)) }?.code == "foreign-bundle")
    try PolicyFixture.writeApp(app, PolicyFixture.clonePlist("second", id: legacyId))
    #expect(f.refusal { try f.policy.checkApp(f.clone("second", bundleId: legacyId)) } == nil)
    #expect(f.refusal { try f.policy.checkApp(f.clone("mv2", bundleId: legacyId)) }?.code == "bundle-id")
  }

  /// Finding 1: `{"appPath":"/Applications/Xcode.app", …}` must never pass, whatever bundle id the entry claims.
  @Test(arguments: [("com.imaxzone.claude.evil", "foreign-bundle"), ("com.apple.dt.Xcode", "bundle-id"),
                    (CloneSpec.vendorBundleId, "bundle-id"), (BuildInfo.bundleId, "bundle-id")])
  func xcodeIsNeverAClone(bundleId: String, code: String) throws {
    let f = try PolicyFixture()
    let entry = f.clone("evil", app: "SystemApplications/Xcode.app", bundleId: bundleId)
    #expect(f.refusal { try f.policy.checkApp(entry) }?.code == code)
  }

  @Test(arguments: ["Documents", ".ssh", "", "Library/Application Support/Claude",
                    "Library/Application Support/ClaudeProfiles", "Library/Application Support/ClaudeProfiles/mv2/Cache",
                    "Library/Application Support/ClaudeProfiles/work", "Library/Application Support/ClaudeProfiles/../mv2",
                    "Library/Application Support/ClaudeProfiles/mv2/.."])
  func onlyItsOwnStandardProfileFolderPasses(profile: String) throws {
    let f = try PolicyFixture()
    #expect(f.refusal { try f.policy.checkProfile(f.clone(profile: profile)) }?.code == "profile-location")
  }

  @Test(arguments: ["Documents", "Documents/Claude mv2.app", "Applications/Sub/Claude mv2.app", "Applications",
                    "Applications/../Documents/Claude mv2.app", "Applications/.Claude mv2.app", "Applications/Claude mv2",
                    "Applications/.app", "SystemApplications"])
  func appsOutsideTheApplicationsFoldersAreRefused(app: String) throws {
    let f = try PolicyFixture()
    #expect(f.refusal { try f.policy.checkApp(f.clone(app: app)) }?.code == "app-location")
  }

  @Test func claudeMultiAccAndTheOfficialAppAreProtected() throws {
    let f = try PolicyFixture()
    for app in ["Applications/ClaudeMultiAcc.app", "SystemApplications/Claude.app", "Applications/claudemultiacc.app"] {
      #expect(f.refusal { try f.policy.checkApp(f.clone("evil", app: app)) }?.code == "protected-app", "\(app)")
    }
  }

  /// APFS ignores letter case by default: `/applications/claude.app` is the official app.
  @Test func aLetterCaseVariantOfTheOfficialAppIsStillRefused() throws {
    let f = try PolicyFixture()
    for app in ["systemapplications/claude.app", "SYSTEMAPPLICATIONS/CLAUDE.APP", "SystemApplications/Claude.APP"] {
      #expect(f.refusal { try f.policy.checkApp(f.clone("evil", app: app)) } != nil, "\(app)")
    }
    #expect(f.exists("SystemApplications/Claude.app/Contents/Info.plist"))
  }

  @Test func symlinkedProfilesAndAppsAreRefused() throws {
    let f = try PolicyFixture()
    let fm = FileManager.default
    let profile = f.profiles.appendingPathComponent("mv2")
    try fm.removeItem(at: profile)
    try fm.createSymbolicLink(at: profile, withDestinationURL: f.root.appendingPathComponent("Documents"))
    #expect(f.refusal { try f.policy.checkProfile(f.clone()) }?.code == "profile-not-a-folder")
    try fm.createSymbolicLink(at: f.userApps.appendingPathComponent("Claude link.app"),
                              withDestinationURL: f.userApps.appendingPathComponent("Claude mv2.app"))
    #expect(f.refusal { try f.policy.checkApp(f.clone("link")) }?.code == "not-a-bundle")
    #expect(f.refusal { try f.policy.checkApp(f.clone("mv2", app: "Applications/Claude link.app")) }?.code
      == "not-a-bundle")
  }

  @Test func filesAndForeignBundlesAreRefused() throws {
    let f = try PolicyFixture()
    try MiniBundle.write(Data("x".utf8), f.userApps.appendingPathComponent("Claude file.app"))
    #expect(f.refusal { try f.policy.checkApp(f.clone("file")) }?.code == "not-a-bundle")
    try MiniBundle.write(Data("x".utf8), f.profiles.appendingPathComponent("file"))
    #expect(f.refusal { try f.policy.checkProfile(f.clone("file")) }?.code == "profile-not-a-folder")
    try FileManager.default.createDirectory(at: f.userApps.appendingPathComponent("Claude bare.app/Contents"),
                                            withIntermediateDirectories: true)
    #expect(f.refusal { try f.policy.checkApp(f.clone("bare")) }?.code == "foreign-bundle")
    try PolicyFixture.writeApp(f.userApps.appendingPathComponent("Claude other.app"), PolicyFixture.clonePlist("mv2"))
    #expect(f.refusal { try f.policy.checkApp(f.clone("other")) }?.code == "foreign-bundle")
    try PolicyFixture.writeApp(f.userApps.appendingPathComponent("Claude wrong.app"),
                               PolicyFixture.clonePlist("wrong", id: "com.imaxzone.claude.mv2"))
    #expect(f.refusal { try f.policy.checkApp(f.clone("wrong")) }?.code == "foreign-bundle")
  }

  @Test func incompleteOrNonCloneEntriesAreRefused() throws {
    let f = try PolicyFixture()
    let official = Instance(slug: testSlug("main"), name: "Claude", kind: .official, bundleId: CloneSpec.vendorBundleId,
                            appPath: f.official.path)
    #expect(f.refusal { try f.policy.checkApp(official) }?.code == "incomplete")
    let noApp = Instance(slug: testSlug("mv2"), name: "Claude mv2", kind: .clone, bundleId: "com.imaxzone.claude.mv2")
    #expect(f.refusal { try f.policy.checkApp(noApp) }?.code == "incomplete")
  }

  @Test func anAppOrProfileUsedByAnotherInstanceIsRefused() throws {
    let f = try PolicyFixture()
    let mine = f.clone()
    let twin = Instance(slug: testSlug("twin"), name: "Twin", kind: .clone, bundleId: "com.imaxzone.claude.twin",
                        appPath: mine.appPath, profileDir: f.root.appendingPathComponent("p/twin").path)
    #expect(f.refusal { try f.policy.checkApp(mine, others: [mine, twin]) }?.code == "shared")
    let cli = Instance(slug: testSlug("alt"), name: "alt", kind: .cliOnly,
                       cliConfigDir: f.profiles.appendingPathComponent("mv2/cli").path)
    #expect(f.refusal { try f.policy.checkProfile(mine, others: [cli]) }?.code == "shared")
    #expect(f.refusal { try f.policy.checkApp(mine, others: [cli]) } == nil)
    let blank = Instance(slug: testSlug("blank"), name: "blank", kind: .cliOnly, appPath: "", profileDir: "", cliConfigDir: "")
    #expect(f.refusal { try f.policy.checkApp(mine, others: [blank]) } == nil)
    #expect(f.refusal { try f.policy.checkProfile(mine, others: [blank]) } == nil)
  }

  /// TOCTOU: what was checked is compared again (device and inode) right before it moves.
  @Test func aSwapAfterTheCheckIsSeen() throws {
    let f = try PolicyFixture()
    let fm = FileManager.default
    let app = try f.policy.checkApp(f.clone())
    try fm.moveItem(at: app.url, to: f.root.appendingPathComponent("away.app"))
    #expect(app.state() == .gone)
    try fm.createDirectory(at: app.url, withIntermediateDirectories: true)
    #expect(app.state() == .changed)
    let fresh = try #require(try f.policy.checkProfile(f.clone("fresh")))
    try fm.createSymbolicLink(at: fresh.url, withDestinationURL: f.root.appendingPathComponent("Documents"))
    #expect(fresh.state() == .changed)
    let profile = try #require(try f.policy.checkProfile(f.clone()))
    try fm.moveItem(at: profile.url, to: f.root.appendingPathComponent("moved"))
    try fm.createSymbolicLink(at: profile.url, withDestinationURL: f.root.appendingPathComponent("moved"))
    #expect(profile.state() == .changed)
  }

  @Test func bundleIdRules() {
    let mv2 = testSlug("mv2")
    #expect(ClonePathPolicy.isCloneBundleId("com.imaxzone.claude.mv2", slug: mv2))
    #expect(ClonePathPolicy.isCloneBundleId("COM.IMAXZONE.CLAUDE.MV2", slug: mv2))
    #expect(!ClonePathPolicy.isCloneBundleId("com.imaxzone.claude.work", slug: mv2))
    #expect(!ClonePathPolicy.isCloneBundleId(CloneSpec.legacySecondBundleId, slug: mv2))
    #expect(ClonePathPolicy.isCloneBundleId(CloneSpec.legacySecondBundleId, slug: testSlug("second")))
    #expect(!ClonePathPolicy.isCloneBundleId(CloneSpec.vendorBundleId, slug: mv2))
    for id in ["com.imaxzone.claude.mv2", "com.imaxzone.claude.5x-akk", CloneSpec.legacySecondBundleId] {
      #expect(ClonePathPolicy.isCloneBundleId(id), "\(id)")
    }
    for id in [CloneSpec.vendorBundleId, BuildInfo.bundleId, "com.apple.dt.Xcode", "com.imaxzone.claude.",
               "com.imaxzone.claude.Has Space", "com.imaxzone.claude.a.b", "com.anthropic.claudefordesktop3", ""] {
      #expect(!ClonePathPolicy.isCloneBundleId(id), "\(id)")
    }
  }

  @Test func tildeAbbreviatesTheHomeFolder() {
    let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    #expect(ClonePathPolicy.tilde(URL(fileURLWithPath: "/Users/test/Library/x"), home: home) == "~/Library/x")
    #expect(ClonePathPolicy.tilde(URL(fileURLWithPath: "/Users/tester/x"), home: home) == "/Users/tester/x")
    #expect(ClonePathPolicy.tilde(URL(fileURLWithPath: "/Applications/A.app"), home: home) == "/Applications/A.app")
  }

  @Test func refusalsHaveRussianMessagesAndEnglishDescriptions() {
    let refusals: [ClonePathRefusal] = [
      .incomplete(name: "A"), .bundleId(name: "A", bundleId: "com.apple.dt.Xcode"),
      .appLocation(name: "A", path: "~/Documents"), .protectedApp(name: "A", path: "/Applications/Claude.app"),
      .notABundle(name: "A", path: "/Applications/A.app"), .foreignBundle(name: "A", path: "/Applications/Xcode.app"),
      .profileLocation(name: "A", path: "~/Documents"), .profileNotAFolder(name: "A", path: "~/x"),
      .shared(name: "A", path: "~/x", other: "b"), .changed(name: "A", path: "~/x"),
    ]
    #expect(Set(refusals.map(\.code)).count == refusals.count)
    for refusal in refusals {
      let message = UserMessage.text(for: refusal)
      #expect(message == refusal.userMessage)
      #expect(message.range(of: "[А-Яа-я]", options: .regularExpression) != nil, "\(refusal)")
      #expect(!message.contains("com."), "\(message)")
      #expect(refusal.description.range(of: "[А-Яа-я]", options: .regularExpression) == nil, "\(refusal)")
      #expect(refusal.description.hasPrefix(refusal.code))
    }
  }
}
