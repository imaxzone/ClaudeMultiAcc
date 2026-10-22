import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct StaticSmokeTests {
  var spec: CloneSpec {
    CloneSpec.newClone(slug: testSlug("work"), displayName: "Claude Work", home: URL(fileURLWithPath: "/Users/t"))
      .with(badge: "W")
  }

  /// A source and a clone that already went through every file-level step (no signing).
  private func makePair(_ root: URL) throws -> (source: URL, clone: URL) {
    let source = try MiniBundle.makeSource(in: root.appendingPathComponent("src"))
    let clone = root.appendingPathComponent("stage/Claude Work.app")
    try FileManager.default.createDirectory(at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: clone)
    let contents = clone.appendingPathComponent("Contents")
    let infoURL = contents.appendingPathComponent("Info.plist")
    try PlistPatcher.patch(try Data(contentsOf: infoURL), spec: spec).write(to: infoURL)
    for junk in ["Contents/embedded.provisionprofile", "Contents/CodeResources", "Icon\r"] {
      try FileManager.default.removeItem(at: clone.appendingPathComponent(junk))
    }
    try FileManager.default.moveItem(at: contents.appendingPathComponent("MacOS/Claude"),
                                     to: contents.appendingPathComponent("MacOS/Claude.real"))
    try MiniBundle.write(MiniBundle.machOBytes, contents.appendingPathComponent("MacOS/Claude"), mode: 0o755)
    let config = LauncherConfigFile(spec: spec, logsDir: URL(fileURLWithPath: "/Users/t/Library/Logs/ClaudeMultiAcc"))
    try config.encoded().write(to: contents.appendingPathComponent("Resources/ClaudeMultiAcc-launcher.json"))
    try TestIcns.badged.write(to: contents.appendingPathComponent("Resources/electron.icns"))
    return (source, clone)
  }

  /// `codesign -dv` reports `vendorTeam` for every target except those whose path ends in a key of `teams`
  /// (`nil` → unsigned: exit 1, no TeamIdentifier); `xattr -l` prints `xattrOutput`.
  private func smoke(
    _ clone: URL, _ source: URL, spec: CloneSpec? = nil, xattrOutput: String = "", teams: [String: String?] = [:],
    allowCustomIcon: Bool = false
  ) async throws -> [SmokeCheck] {
    let runner = ScriptedRunner { request in
      guard request.executable.lastPathComponent == "codesign" else { return .ok(stdout: xattrOutput) }
      let target = request.arguments.last ?? ""
      let team = teams.first { target.hasSuffix($0.key) }.map(\.value) ?? Self.vendorTeam
      guard let team else { return .fail(1, stderr: "\(target): code object is not signed at all\n") }
      return .ok(stderr: "Identifier=x\nTeamIdentifier=\(team)\n")
    }
    return try await StaticSmoke(runner: runner)
      .run(app: clone, source: source, spec: spec ?? self.spec, allowCustomIcon: allowCustomIcon)
  }

  static let vendorTeam: String? = "Q6L2SF6YDW"

  @Test func everyCheckPassesOnAProperClone() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let checks = try await smoke(clone, source)
    #expect(checks.allSatisfy { $0.passed }, "\(checks.filter { !$0.passed })")
    #expect(checks.map(\.name) == [
      "info-id", "display-name", "bundle-name-claude", "no-icon-name", "url-types-claude-only", "doc-types-allowed",
      "launcher-is-macho", "claude-real-present", "launcher-config-valid", "vendor-frameworks-intact", "no-finder-info",
      "no-icon-r", "no-provisionprofile", "no-codesources-ticket", "helpers-untouched", "asar-integrity-unchanged",
      "icns-badged", "icns-no-1x-small",
    ])
    #expect(checks.first { $0.name == "icns-badged" } == SmokeCheck("icns-badged", true, "differs from source"))
    #expect(checks.last == SmokeCheck("icns-no-1x-small", true, "8 images, none 1x 16/32 pt"))
  }

  @Test func detectsLeftoversAndUnpatchedFiles() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let contents = clone.appendingPathComponent("Contents")
    try FileManager.default.copyItem(at: source.appendingPathComponent("Contents/Info.plist"),
                                     to: root.appendingPathComponent("vendor.plist"))
    _ = try FileManager.default.replaceItemAt(contents.appendingPathComponent("Info.plist"),
                                              withItemAt: root.appendingPathComponent("vendor.plist"))
    try Data().write(to: clone.appendingPathComponent("Icon\r"))
    try Data("x".utf8).write(to: contents.appendingPathComponent("embedded.provisionprofile"))
    try Data("x".utf8).write(to: contents.appendingPathComponent("CodeResources"))
    try Data("#!/bin/sh\n".utf8).write(to: contents.appendingPathComponent("MacOS/Claude"))
    try FileManager.default.removeItem(at: contents.appendingPathComponent("MacOS/Claude.real"))
    try FileManager.default.copyItem(at: source.appendingPathComponent("Contents/Resources/electron.icns"),
                                     to: root.appendingPathComponent("e.icns"))
    _ = try FileManager.default.replaceItemAt(contents.appendingPathComponent("Resources/electron.icns"),
                                              withItemAt: root.appendingPathComponent("e.icns"))
    let checks = try await smoke(clone, source, xattrOutput: "com.apple.FinderInfo: 00 00\n")
    let failed = Set(checks.filter { !$0.passed }.map(\.name))
    #expect(failed == [
      "info-id", "display-name", "no-icon-name", "url-types-claude-only", "doc-types-allowed", "launcher-is-macho",
      "claude-real-present", "no-finder-info", "no-icon-r", "no-provisionprofile", "no-codesources-ticket", "icns-badged",
      "icns-no-1x-small",
    ])
  }

  @Test func detectsHelperAndAsarTampering() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let helperInfo = clone.appendingPathComponent("Contents/Frameworks/Claude Helper.app/Contents/Info.plist")
    var helper = try plistDict(try Data(contentsOf: helperInfo))
    helper["CFBundleIdentifier"] = "com.imaxzone.claude.work.helper"
    try PropertyListSerialization.data(fromPropertyList: helper, format: .xml, options: 0).write(to: helperInfo)
    let infoURL = clone.appendingPathComponent("Contents/Info.plist")
    var info = try plistDict(try Data(contentsOf: infoURL))
    info["ElectronAsarIntegrity"] = ["Resources/app.asar": ["algorithm": "SHA256", "hash": "ff"]]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let failed = Set(try await smoke(clone, source).filter { !$0.passed }.map(\.name))
    #expect(failed == ["helpers-untouched", "asar-integrity-unchanged"])
  }

  @Test func launcherConfigMustMatchSpec() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let other = CloneSpec.newClone(slug: testSlug("other"), displayName: "Claude Work", home: URL(fileURLWithPath: "/Users/t"))
    let config = LauncherConfigFile(spec: other, logsDir: URL(fileURLWithPath: "/l"))
    try config.encoded().write(to: clone.appendingPathComponent("Contents/Resources/ClaudeMultiAcc-launcher.json"))
    let checks = try await smoke(clone, source)
    #expect(checks.first { $0.name == "launcher-config-valid" }?.passed == false)
  }

  /// R1: the badge lives in `electron.icns` (baked before signing); without a badge the vendor's file stays.
  @Test func icnsMustBeBadgedOnlyWhenABadgeIsRequested() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let plain = try #require(try await smoke(clone, source, spec: spec.with(badge: nil)).first { $0.name == "icns-badged" })
    #expect(plain == .skipped("icns-badged", "no badge requested"))
    let icns = clone.appendingPathComponent("Contents/Resources/electron.icns")
    try FileManager.default.removeItem(at: icns)
    try FileManager.default.copyItem(at: source.appendingPathComponent("Contents/Resources/electron.icns"), to: icns)
    let unbadged = try #require(try await smoke(clone, source).first { $0.name == "icns-badged" })
    #expect(unbadged == SmokeCheck("icns-badged", false, "identical to source or missing"))
  }

  /// A clone built the old way carries the 1× 16/32 pt entries (`ic04`/`ic05`, or `is32`/`il32` with their masks),
  /// which put it on macOS 26+'s grey legacy platter at small 1× sizes; a file that is not an icns fails too.
  @Test(arguments: [
    (TestIcns.make(TestIcns.written + ["ic04", "ic05", "info"]), "1x small entries: ic04,ic05"),
    (TestIcns.make(["is32", "s8mk", "il32", "l8mk"] + TestIcns.written), "1x small entries: is32,s8mk,il32,l8mk"),
    (TestIcns.make(["ic12", "ic05", "ic10"]), "1x small entries: ic05"),
    (Data("icns-badged".utf8), "missing or not an icns file"),
  ])
  func anIcnsWith1xSmallEntriesFails(icns: Data, detail: String) async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    try icns.write(to: clone.appendingPathComponent("Contents/Resources/electron.icns"))
    let checks = try await smoke(clone, source)
    #expect(checks.first { $0.name == "icns-no-1x-small" } == SmokeCheck("icns-no-1x-small", false, detail))
    #expect(checks.first { $0.name == "icns-badged" }?.passed == true)
  }

  /// Without a badge the clone keeps the vendor's `electron.icns`, which is not ours to judge.
  @Test func small1xEntriesAreNotCheckedWithoutABadge() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    try TestIcns.make(TestIcns.written + ["ic04", "ic05"])
      .write(to: clone.appendingPathComponent("Contents/Resources/electron.icns"))
    let check = try #require(try await smoke(clone, source, spec: spec.with(badge: nil)).first { $0.name == "icns-no-1x-small" })
    #expect(check == .skipped("icns-no-1x-small", "no badge requested"))
  }

  @Test func aMissingIcnsFailsTheSmall1xCheck() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    try FileManager.default.removeItem(at: clone.appendingPathComponent("Contents/Resources/electron.icns"))
    let check = try #require(try await smoke(clone, source).first { $0.name == "icns-no-1x-small" })
    #expect(check == SmokeCheck("icns-no-1x-small", false, "missing or not an icns file"))
  }

  /// Without `CFBundleIconName` macOS shows `electron.icns`; a kept name would show the unbadged Assets.car icon.
  @Test func aKeptIconNameFails() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let infoURL = clone.appendingPathComponent("Contents/Info.plist")
    var info = try plistDict(try Data(contentsOf: infoURL))
    #expect(info["CFBundleIconName"] == nil)
    info["CFBundleIconName"] = "Claude"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let check = try #require(try await smoke(clone, source).first { $0.name == "no-icon-name" })
    #expect(check == SmokeCheck("no-icon-name", false, "Claude"))
  }

  /// An unbadged clone shows the vendor's Assets.car icon: its icon name must stay.
  @Test func anUnbadgedCloneMustKeepTheIconName() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let unbadged = spec.with(badge: nil)
    let infoURL = clone.appendingPathComponent("Contents/Info.plist")
    let original = try plistDict(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")))
    try PlistPatcher.patch(try PropertyListSerialization.data(fromPropertyList: original, format: .xml, options: 0),
                           spec: unbadged).write(to: infoURL)
    let kept = try #require(try await smoke(clone, source, spec: unbadged).first { $0.name == "icon-name-kept" })
    #expect(kept.passed)
    var info = try plistDict(try Data(contentsOf: infoURL))
    info.removeValue(forKey: "CFBundleIconName")
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let missing = try #require(try await smoke(clone, source, spec: unbadged).first { $0.name == "icon-name-kept" })
    #expect(missing == SmokeCheck("icon-name-kept", false, "absent"))
  }

  /// No Dock-tile plugin any more: StaticSmoke no longer looks at `NSDockTilePlugIn` (old clones keep theirs).
  @Test func anOldDockTilePluginDeclarationIsNotChecked() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let infoURL = clone.appendingPathComponent("Contents/Info.plist")
    var info = try plistDict(try Data(contentsOf: infoURL))
    info["NSDockTilePlugIn"] = "ClaudeUsageTile_work.docktileplugin"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let checks = try await smoke(clone, source)
    #expect(checks.allSatisfy { $0.passed } && !checks.contains { $0.name == "plugin-declared" })
  }

  /// `cmacc instance verify` on a clone built before R1: its Finder custom icon (`Icon\r` + FinderInfo) is tolerated.
  @Test func customIconIsToleratedOnlyWhenAllowed() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let finderInfo = "com.apple.FinderInfo: 00 00\n"
    let strictFailed = Set(try await smoke(clone, source, xattrOutput: finderInfo).filter { !$0.passed }.map(\.name))
    #expect(strictFailed == ["no-finder-info"])
    try Data().write(to: clone.appendingPathComponent("Icon\r"))
    let strict = Set(try await smoke(clone, source, xattrOutput: finderInfo).filter { !$0.passed }.map(\.name))
    #expect(strict == ["no-finder-info", "no-icon-r"])
    let allowed = try await smoke(clone, source, xattrOutput: finderInfo, allowCustomIcon: true)
    #expect(allowed.allSatisfy { $0.passed }, "\(allowed.filter { !$0.passed })")
    #expect(allowed.first { $0.name == "no-icon-r" }?.detail == "skipped: custom icon of an installed clone")
    #expect(allowed.first { $0.name == "no-finder-info" }?.detail == "skipped: custom icon of an installed clone")
  }

  @Test func finderInfoWithoutAnIconFileStillFailsWhenAllowed() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let checks = try await smoke(clone, source, xattrOutput: "com.apple.FinderInfo: 00\n", allowCustomIcon: true)
    #expect(checks.first { $0.name == "no-finder-info" }?.passed == false)
  }

  @Test func intactVendorFrameworksPass() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let check = try #require(try await smoke(clone, source).first { $0.name == "vendor-frameworks-intact" })
    #expect(check == SmokeCheck("vendor-frameworks-intact", true, "2 bundles signed by Q6L2SF6YDW, ShipIt present"))
  }

  /// A re-signed Squirrel.framework is what made every vendor helper crash at launch ("different Team IDs").
  @Test(arguments: [
    ("Squirrel.framework", String?.some("LOCAL12345"), "Squirrel.framework=LOCAL12345"),
    ("Claude Helper.app", String?.some("not set"), "Claude Helper.app=not set"),
    ("Squirrel.framework", String?.none, "Squirrel.framework=unsigned"),
  ])
  func frameworkWithAnotherTeamFails(bundle: String, team: String?, detail: String) async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let checks = try await smoke(clone, source, teams: ["Contents/Frameworks/\(bundle)": team])
    let check = try #require(checks.first { $0.name == "vendor-frameworks-intact" })
    #expect(!check.passed)
    #expect(check.detail.contains(detail) && check.detail.contains("expected Q6L2SF6YDW"), "\(check.detail)")
  }

  @Test func missingShipItFails() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    try FileManager.default.removeItem(at: clone.appendingPathComponent(VendorFrameworksCheck.shipItPath))
    let check = try #require(try await smoke(clone, source).first { $0.name == "vendor-frameworks-intact" })
    #expect(check == SmokeCheck("vendor-frameworks-intact", false, "ShipIt missing from Squirrel.framework"))
  }

  @Test func unknownSourceTeamFails() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let checks = try await smoke(clone, source, teams: [source.lastPathComponent: nil])
    #expect(checks.first { $0.name == "vendor-frameworks-intact" }
      == SmokeCheck("vendor-frameworks-intact", false, "source Team ID unknown"))
  }

  /// The pipeline passes the Team ID it captured before `recheck-source`; the live source is never consulted.
  @Test func snapshotTeamIsUsedWithoutReadingTheSource() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let facts = SourceFacts.read(from: source, teamId: "Q6L2SF6YDW")
    #expect(facts.teamId == "Q6L2SF6YDW" && facts.hasShipIt)
    try FileManager.default.removeItem(at: source)
    let runner = ScriptedRunner { request in
      request.executable.lastPathComponent == "codesign" ? .ok(stderr: "TeamIdentifier=Q6L2SF6YDW\n") : .ok()
    }
    let checks = try await StaticSmoke(runner: runner).run(app: clone, reference: facts, spec: spec)
    #expect(checks.first { $0.name == "vendor-frameworks-intact" }?.passed == true)
    #expect(!runner.recorded.contains { $0.arguments.contains { $0.hasPrefix(source.path) } })
  }

  @Test func missingClaudeSchemeFails() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (source, clone) = try makePair(root)
    let infoURL = clone.appendingPathComponent("Contents/Info.plist")
    var info = try plistDict(try Data(contentsOf: infoURL))
    info["CFBundleURLTypes"] = [[String: Any]]()
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
    let checks = try await smoke(clone, source)
    #expect(checks.first { $0.name == "url-types-claude-only" }?.passed == false)
  }

  @Test func machOMagicDetection() {
    #expect(StaticSmoke.isMachO(Data([0xCF, 0xFA, 0xED, 0xFE])))
    #expect(StaticSmoke.isMachO(Data([0xCA, 0xFE, 0xBA, 0xBE])))
    #expect(!StaticSmoke.isMachO(Data("#!/b".utf8)))
    #expect(!StaticSmoke.isMachO(Data([0xCF])))
  }
}

/// Hand-built `.icns` bytes (`icns` + big-endian total length, then type + big-endian length + payload per entry).
enum TestIcns {
  /// The eight types `IcnsTool.writeIcns` produces (via `iconutil`).
  static let written = ["ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10", "ic11"]

  /// What a badged clone's `electron.icns` looks like to `StaticSmoke`: the eight types plus iconutil's `info`.
  static let badged = make(written + ["info"])

  /// Empty payloads, so a file of up to 14 entries is plain ASCII (every byte below 0x80).
  static func make(_ types: [String]) -> Data {
    let body = types.reduce(Data()) { data, type in data + Data(type.utf8) + bigEndian(8) }
    return Data("icns".utf8) + bigEndian(body.count + 8) + body
  }

  static func bigEndian(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
  }
}
