import Foundation
import Support
import Testing
@testable import LinkRouter

/// L6: sign-in links and the system-wide `claude://` handler only ever go to the app whose bundle id is the one expected.
@Suite struct LinkTargetIdentityTests {
  private let impostor = URL(fileURLWithPath: "/Applications/Impostor.app")

  @Test func handBackRefusesAnAppThatIsNotTheOfficialClaude() async {
    for found in ["com.imaxzone.claude.mv2", "com.apple.Safari", nil] as [String?] {
      let api = FakeSchemeAPI(handler: ownApp, identities: found.map { [impostor: $0] } ?? [:])
      guard case .failed(let message) = await SchemeOwnership(api: api, ownApp: ownApp).handBack(to: impostor) else {
        Issue.record("handed back to \(found ?? "nil")")
        continue
      }
      #expect(message.contains("not com.anthropic.claudefordesktop"))
      #expect(api.setHandlerCalls.isEmpty && api.current == ownApp)
    }
  }

  @Test func handBackToTheRealOfficialClaudeGoesAhead() async {
    let api = FakeSchemeAPI(handler: ownApp, identities: [claudeApp: "COM.anthropic.claudefordesktop"])
    #expect(await SchemeOwnership(api: api, ownApp: ownApp).handBack(to: claudeApp) == .handedBack)
    #expect(api.setHandlerCalls == [claudeApp])
  }

  @Test func theBundleIdIsReadFreshFromInfoPlist() throws {
    let app = try makeTempDir().appendingPathComponent("Fake.app")
    #expect(AppIdentity.bundleId(of: app) == nil)
    try writeInfo(app, id: "com.example.first")
    #expect(AppIdentity.bundleId(of: app) == "com.example.first")
    try writeInfo(app, id: "com.example.second")
    #expect(AppIdentity.bundleId(of: app) == "com.example.second")
  }

  @Test func onlyClaudeDesktopAndItsClonesAreLinkTargets() {
    for id in [OfficialApp.bundleId, "com.anthropic.claudefordesktop2", "com.imaxzone.claude.mv2", "COM.IMAXZONE.CLAUDE.MV2"] {
      #expect(AppIdentity.isClaudeDesktop(id), "\(id)")
    }
    for id in ["com.apple.Safari", "com.imaxzone.ClaudeMultiAcc", "com.imaxzone.claude.", "com.imaxzone.claude.a b",
               "com.anthropic.claudefordesktop3", "com.anthropic.claude", ""] {
      #expect(!AppIdentity.isClaudeDesktop(id), "\(id)")
    }
  }

  /// The live delivery refuses before NSWorkspace is asked (only the gate is called here: tests never open apps).
  @Test func deliveryRefusesAnythingButClaudeDesktop() {
    let ids: [URL: String] = [
      URL(fileURLWithPath: "/A/Claude.app"): OfficialApp.bundleId, URL(fileURLWithPath: "/A/mv2.app"): "com.imaxzone.claude.mv2",
      URL(fileURLWithPath: "/A/Safari.app"): "com.apple.Safari", URL(fileURLWithPath: "/A/Me.app"): BuildInfo.bundleId,
    ]
    let delivery = WorkspaceDelivery(identify: { ids[$0] })
    #expect(throws: Never.self) { try delivery.check(URL(fileURLWithPath: "/A/Claude.app")) }
    #expect(throws: Never.self) { try delivery.check(URL(fileURLWithPath: "/A/mv2.app")) }
    for path in ["/A/Safari.app", "/A/Me.app", "/A/Missing.app"] {
      let app = URL(fileURLWithPath: path)
      #expect(throws: DeliveryError.unexpectedApp(path: path, bundleId: ids[app])) { try delivery.check(app) }
    }
    #expect(DeliveryError.unexpectedApp(path: "/A/Safari.app", bundleId: "com.apple.Safari").description
      .contains("/A/Safari.app"))
  }

  @Test func aCloneWhoseAppIsAnotherBundleNeverWaitsForSignIn() throws {
    let root = try makeTempDir()
    let instances = try fourInstances(root: root)
    let work = root.appendingPathComponent("Applications/Claude Work.app")
    let second = root.appendingPathComponent("Applications/Claude 2nd.app")
    let swapped: [URL: String] = [work: "com.apple.Safari", second: "com.anthropic.claudefordesktop2"]
    #expect(SignInCandidate.clones(from: instances) { swapped[$0] }.map(\.slug) == ["second"])
    let right: [URL: String] = [work: "COM.imaxzone.claude.work"]
    #expect(SignInCandidate.clones(from: instances) { right[$0] }.map(\.slug) == ["second", "work"])
  }

  @Test func anOfficialEntryWhoseAppIsAnotherBundleIsSkipped() throws {
    let root = try makeTempDir()
    let official = root.appendingPathComponent("Applications/Claude.app")
    let instances = try fourInstances(root: root)
    #expect(OfficialApp.from(instances) { _ in "com.imaxzone.claude.work" } == nil)
    #expect(OfficialApp.from(instances) { [official: OfficialApp.bundleId][$0] } == official)
    #expect(OfficialApp.from(instances) { _ in nil } == official)
  }

  @Test func theDefaultOfficialAppCountsOnlyWhenItIsTheOfficialClaude() {
    #expect(OfficialApp.installedDefault { _ in OfficialApp.bundleId } == OfficialApp.defaultPath)
    #expect(OfficialApp.installedDefault { _ in "com.imaxzone.claude.mv2" } == nil)
    #expect(OfficialApp.installedDefault { _ in nil } == nil)
  }

  private func writeInfo(_ app: URL, id: String) throws {
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
    try plist.write(to: contents.appendingPathComponent("Info.plist"))
  }
}
