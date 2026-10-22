import Foundation
import Testing
@testable import InstanceBuilder

@Suite struct PlistPatcherTests {
  let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
  var spec: CloneSpec { CloneSpec.newClone(slug: testSlug("work"), displayName: "Claude Work", home: home) }

  private func patched(_ spec: CloneSpec? = nil) throws -> [String: Any] {
    let data = try PlistPatcher.patch(try fixtureData("Info-claude.plist"), spec: spec ?? self.spec)
    return try plistDict(data)
  }

  @Test func setsIdentifierDisplayNameAndSlug() throws {
    let info = try patched()
    #expect(info["CFBundleIdentifier"] as? String == "com.imaxzone.claude.work")
    #expect(info["CFBundleDisplayName"] as? String == "Claude Work")
    #expect(info["CFBundleName"] as? String == "Claude")
    #expect(info["ClaudeMultiAccSlug"] as? String == "work")
  }

  /// R1: a badged clone shows its own `electron.icns`, so the vendor's Assets.car icon name goes (the Assets.car file
  /// itself stays: Claude loads runtime images from it).
  @Test func aBadgedCloneDropsTheIconNameButKeepsTheIconFile() throws {
    let info = try patched(spec.with(badge: "W"))
    #expect(info["CFBundleIconName"] == nil)
    #expect(info["CFBundleIconFile"] as? String == "electron.icns")
  }

  /// Without a badge the clone keeps the vendor's new-format Assets.car icon: the unbadged `electron.icns` carries
  /// the 1x 16/32 pt images that macOS 26+ puts on the grey legacy platter.
  @Test func anUnbadgedCloneKeepsTheVendorIconName() throws {
    let info = try patched(spec.with(badge: nil))
    #expect(info["CFBundleIconName"] as? String != nil)
    #expect(info["CFBundleIconFile"] as? String == "electron.icns")
  }

  @Test func keepsOnlyClaudeURLScheme() throws {
    let types = try #require(try patched()["CFBundleURLTypes"] as? [[String: Any]])
    #expect(types.count == 1)
    #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["claude"])
  }

  @Test func dropsURLTypeWhenAnySchemeIsNotClaude() throws {
    var source = try plistDict(try fixtureData("Info-claude.plist"))
    source["CFBundleURLTypes"] = [["CFBundleURLSchemes": ["claude", "msauth.x"]], ["CFBundleURLSchemes": ["claude"]]]
    let data = try PropertyListSerialization.data(fromPropertyList: source, format: .xml, options: 0)
    let info = try plistDict(try PlistPatcher.patch(data, spec: spec))
    #expect((info["CFBundleURLTypes"] as? [[String: Any]])?.count == 1)
  }

  @Test func keepsOnlyAllowedDocumentTypesAsAlternate() throws {
    let types = try #require(try patched()["CFBundleDocumentTypes"] as? [[String: Any]])
    let names = types.compactMap { $0["CFBundleTypeName"] as? String }
    #expect(names == ["Desktop Extension", "Skill File", "Skill File"])
    #expect(types.allSatisfy { $0["LSHandlerRank"] as? String == "Alternate" })
  }

  @Test func movesExportedTypesToImported() throws {
    let info = try patched()
    #expect(info["UTExportedTypeDeclarations"] == nil)
    let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
    let ids = imported.compactMap { $0["UTTypeIdentifier"] as? String }
    #expect(ids.sorted() == ["com.anthropic.skill", "net.daringfireball.markdown"])
  }

  @Test func mergeByIdentifierDoesNotDuplicate() throws {
    var source = try plistDict(try fixtureData("Info-claude.plist"))
    let skill: [String: Any] = ["UTTypeIdentifier": "com.anthropic.skill", "UTTypeDescription": "Exported"]
    source["UTImportedTypeDeclarations"] = [["UTTypeIdentifier": "com.anthropic.skill", "UTTypeDescription": "Old"]]
    source["UTExportedTypeDeclarations"] = [skill]
    let data = try PropertyListSerialization.data(fromPropertyList: source, format: .xml, options: 0)
    let info = try plistDict(try PlistPatcher.patch(data, spec: spec))
    let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
    #expect(imported.count == 1)
    #expect(imported.first?["UTTypeDescription"] as? String == "Exported")
  }

  @Test func leavesElectronKeysUntouched() throws {
    let source = try plistDict(try fixtureData("Info-claude.plist"))
    let info = try patched()
    for key in ["ElectronAsarIntegrity", "ElectronTeamID", "LSEnvironment"] {
      let before = try #require(source[key])
      let after = try #require(info[key])
      #expect(NSDictionary(dictionary: [key: before]).isEqual(to: [key: after]))
    }
  }

  @Test func isIdempotent() throws {
    let once = try PlistPatcher.patch(try fixtureData("Info-claude.plist"), spec: spec)
    let info = try plistDict(try PlistPatcher.patch(once, spec: spec))
    #expect(NSDictionary(dictionary: info).isEqual(to: try plistDict(once)))
    #expect((info["UTImportedTypeDeclarations"] as? [Any])?.count == 2)
  }

  @Test func refusesUnexpectedBundleName() throws {
    var source = try plistDict(try fixtureData("Info-claude.plist"))
    source["CFBundleName"] = "Claude 2nd"
    let data = try PropertyListSerialization.data(fromPropertyList: source, format: .xml, options: 0)
    #expect(throws: BuilderError.unexpectedBundleName("Claude 2nd")) {
      try PlistPatcher.patch(data, spec: spec)
    }
  }

  @Test func refusesVendorBundleIds() throws {
    let data = try fixtureData("Info-claude.plist")
    for id in ["com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.work", "com.anthropic.claudefordesktop2",
               "com.anthropic.claude", "com.anthropic.foo.bar", "Com.Anthropic.ClaudeForDesktop"] {
      let bad = CloneSpec(slug: testSlug("work"), displayName: "W", bundleId: id,
                          profileDir: URL(fileURLWithPath: "/tmp/p"), badge: nil)
      #expect(throws: BuilderError.vendorBundleId(id)) { try PlistPatcher.patch(data, spec: bad) }
    }
  }

  @Test func allowsLegacySecondId() throws {
    let info = try patched(CloneSpec.second(home: home))
    #expect(info["CFBundleIdentifier"] as? String == "com.anthropic.claudefordesktop2")
    #expect(info["CFBundleDisplayName"] as? String == "Claude 2nd")
  }

  @Test func rejectsGarbage() {
    #expect(throws: BuilderError.self) { try PlistPatcher.patch(Data("nope".utf8), spec: spec) }
  }
}
