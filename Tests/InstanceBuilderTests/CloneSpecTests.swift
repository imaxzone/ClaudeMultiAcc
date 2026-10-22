import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite(.russian) struct CloneSpecTests {
  let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

  @Test func newCloneUsesOwnIdNamespaceAndProfilesDir() {
    let spec = CloneSpec.newClone(slug: testSlug("work"), displayName: "Claude Work", home: home)
    #expect(spec.bundleId == "com.imaxzone.claude.work")
    #expect(spec.displayName == "Claude Work")
    #expect(spec.profileDir.path == "/Users/tester/Library/Application Support/ClaudeProfiles/work")
    #expect(spec.badge == nil)
  }

  @Test func secondKeepsLegacyIdentity() {
    let spec = CloneSpec.second(home: home)
    #expect(spec.slug.raw == "second")
    #expect(spec.bundleId == "com.anthropic.claudefordesktop2")
    #expect(spec.displayName == "Claude 2nd")
    #expect(spec.profileDir.path == "/Users/tester/Library/Application Support/ClaudeProfiles/second")
    #expect(spec.badge == "2nd")
  }

  @Test func withReturnsModifiedCopy() {
    let spec = CloneSpec.newClone(slug: testSlug("work"), displayName: "Claude Work", home: home)
    let changed = spec.with(badge: "W")
    #expect(changed.badge == "W")
    #expect(spec.badge == nil)
    #expect(changed.bundleId == spec.bundleId)
  }

  @Test func fromInstanceCoversEveryCloneInFourInstanceFixture() throws {
    let instances = try fourInstances(root: URL(fileURLWithPath: "/tmp/root"))
    #expect(instances.count >= 4)
    let clones = instances.filter { $0.kind == .clone }
    #expect(clones.count == 2)
    for instance in clones {
      let spec = try CloneSpec.from(instance: instance)
      #expect(spec.slug == instance.slug)
      #expect(spec.bundleId == instance.bundleId)
      #expect(spec.displayName == instance.name)
      #expect(spec.profileDir.path == instance.profileDir)
      #expect(spec.badge == instance.badge)
    }
    let second = try CloneSpec.from(instance: try #require(clones.first { $0.slug.raw == "second" }))
    #expect(second == CloneSpec.second(home: home).with(profileDir: URL(fileURLWithPath: "/tmp/root/profiles/second", isDirectory: true)))
  }

  @Test func fromInstanceRejectsOfficialAndCliOnly() throws {
    let instances = try fourInstances(root: URL(fileURLWithPath: "/tmp/root"))
    for instance in instances where instance.kind != .clone {
      #expect(throws: BuilderError.notAClone(instance.slug.raw)) { try CloneSpec.from(instance: instance) }
    }
  }

  @Test func fromInstanceRejectsVendorIdOnOtherSlug() throws {
    let instance = Instance(
      slug: testSlug("sneaky"), name: "Sneaky", kind: .clone, bundleId: "com.anthropic.claudefordesktop2",
      profileDir: "/tmp/p")
    #expect(throws: BuilderError.vendorBundleId("com.anthropic.claudefordesktop2")) {
      try CloneSpec.from(instance: instance)
    }
  }

  @Test func anthropicNamespaceIsRefusedCaseInsensitively() {
    let other = testSlug("other")
    let second = testSlug("second")
    for id in ["com.anthropic.claude", "com.anthropic.foo.bar", "Com.Anthropic.ClaudeForDesktop",
               "com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.work"] {
      #expect(throws: BuilderError.vendorBundleId(id)) { try CloneSpec.checkBundleId(id, slug: second) }
      #expect(throws: BuilderError.vendorBundleId(id)) { try CloneSpec.checkBundleId(id, slug: other) }
    }
    #expect(throws: BuilderError.vendorBundleId("COM.ANTHROPIC.CLAUDEFORDESKTOP2")) {
      try CloneSpec.checkBundleId("COM.ANTHROPIC.CLAUDEFORDESKTOP2", slug: other)
    }
    #expect(throws: Never.self) { try CloneSpec.checkBundleId("COM.ANTHROPIC.CLAUDEFORDESKTOP2", slug: second) }
    #expect(throws: Never.self) { try CloneSpec.checkBundleId("com.anthropic.claudefordesktop2", slug: second) }
    #expect(throws: Never.self) { try CloneSpec.checkBundleId("com.imaxzone.claude.work", slug: other) }
  }

  @Test func fromInstanceRefusesAnthropicIdOnClone() {
    let instance = Instance(slug: testSlug("work"), name: "W", kind: .clone, bundleId: "com.anthropic.claude", profileDir: "/tmp/p")
    #expect(throws: BuilderError.vendorBundleId("com.anthropic.claude")) { try CloneSpec.from(instance: instance) }
  }

  @Test func fromInstanceRequiresBundleIdAndProfile() {
    let noId = Instance(slug: testSlug("x"), name: "X", kind: .clone, profileDir: "/tmp/p")
    #expect(throws: BuilderError.incompleteInstance("x")) { try CloneSpec.from(instance: noId) }
    let noProfile = Instance(slug: testSlug("x"), name: "X", kind: .clone, bundleId: "com.imaxzone.claude.x")
    #expect(throws: BuilderError.incompleteInstance("x")) { try CloneSpec.from(instance: noProfile) }
  }

  private func fourInstances(root: URL) throws -> [Instance] {
    struct File: Decodable { let instances: [Instance] }
    let text = try String(contentsOf: fixtureURL("instances-four.json"), encoding: .utf8)
      .replacingOccurrences(of: "{{ROOT}}", with: root.path)
    return try JSONCoding.decoder.decode(File.self, from: Data(text.utf8)).instances
  }
}

@Suite(.russian) struct StagedSpecTests {
  @Test func reconstructsSpecFromStagedBundleAndReport() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = CloneSpec.newClone(slug: testSlug("stagetest"), displayName: "Claude Stagetest", home: root)
      .with(badge: "T")
    let app = try MiniBundle.makeSource(in: root.appendingPathComponent("b.noindex"))
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    try PlistPatcher.patch(try Data(contentsOf: infoURL), spec: spec).write(to: infoURL)
    try LauncherConfigFile(spec: spec, logsDir: root).encoded()
      .write(to: app.appendingPathComponent("Contents/Resources/ClaudeMultiAcc-launcher.json"))
    // Reports written before 2026-09-30 still carry the retired `neutralizeUpdater` flag; it is ignored.
    let report = #"{"badge":"T","neutralizeUpdater":false}"#
    try Data(report.utf8).write(to: root.appendingPathComponent("b.noindex/build-report.json"))
    #expect(try CloneSpec.fromStagedApp(app) == spec)
  }

  @Test func withoutReportAssumesNoBadge() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = CloneSpec.newClone(slug: testSlug("stagetest"), displayName: "Claude Stagetest", home: root)
    let app = try MiniBundle.makeSource(in: root)
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    try PlistPatcher.patch(try Data(contentsOf: infoURL), spec: spec).write(to: infoURL)
    try LauncherConfigFile(spec: spec, logsDir: root).encoded()
      .write(to: app.appendingPathComponent("Contents/Resources/ClaudeMultiAcc-launcher.json"))
    #expect(try CloneSpec.fromStagedApp(app) == spec)
  }

  @Test func unpatchedBundleIsRejected() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root)
    #expect(throws: BuilderError.self) { try CloneSpec.fromStagedApp(app) }
  }
}

/// L3: the display name becomes the app's file name, so the CLI and registry paths reject what the add window rejects.
@Suite(.russian) struct CloneSpecDisplayNameTests {
  @Test(arguments: ["Claude Work", "Claude 5x акк", "Работа", "Claude 🚀", "Claude 👩‍💻", "Claude (alt)"])
  func ordinaryNamesPass(name: String) throws {
    try CloneSpec.checkDisplayName(name)
  }

  @Test(arguments: ["", ".Claude", "Claude/Work", "Claude:Work", " Claude", "Claude ", String(repeating: "x", count: 65),
                    "Claude\u{0}Work", "Claude\tWork", "Claude\nWork", "Claude\rWork", "Claude\u{7}", "Claude\u{1B}[0m",
                    "Claude\u{2028}Work", "Claude\u{2029}Work", "Claude \u{202E}ppa.exe", "Claude\u{200F}", "Claude\u{2066}x",
                    "Claude\u{061C}x", "Claude\u{85}x"])
  func controlCharactersBidiOverridesAndPathSeparatorsAreRejected(name: String) {
    #expect(throws: BuilderError.invalidDisplayName(name)) { try CloneSpec.checkDisplayName(name) }
  }
}
