import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct LauncherInstallerTests {
  let spec = CloneSpec.newClone(slug: testSlug("stagetest"), displayName: "Claude Stagetest", home: URL(fileURLWithPath: "/Users/u"))
  let logs = URL(fileURLWithPath: "/Users/u/Library/Logs/ClaudeMultiAcc", isDirectory: true)

  @Test func configMatchesBriefSchema() throws {
    let json = try LauncherConfigFile(spec: spec, logsDir: logs).encoded()
    let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["slug"] as? String == "stagetest")
    #expect(object["bundleId"] as? String == "com.imaxzone.claude.stagetest")
    #expect(object["profileDir"] as? String == "/Users/u/Library/Application Support/ClaudeProfiles/stagetest")
    #expect(object["realExecutable"] as? String == "Claude.real")
    #expect(object["logFile"] as? String == "/Users/u/Library/Logs/ClaudeMultiAcc/launcher-stagetest.log")
    #expect(object.count == 6)
  }

  @Test func installMovesElectronAndWritesLauncherAndConfig() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root, executable: Data("electron".utf8))
    let launcher = root.appendingPathComponent("CloneLauncher")
    try MiniBundle.write(MiniBundle.machOBytes, launcher, mode: 0o755)
    try LauncherInstaller().install(into: app, spec: spec, launcherBinary: launcher, logsDir: logs)
    let macOS = app.appendingPathComponent("Contents/MacOS")
    #expect(try Data(contentsOf: macOS.appendingPathComponent("Claude.real")) == Data("electron".utf8))
    #expect(try Data(contentsOf: macOS.appendingPathComponent("Claude")) == MiniBundle.machOBytes)
    let mode = try FileManager.default.attributesOfItem(atPath: macOS.appendingPathComponent("Claude").path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o755)
    let config = try JSONDecoder().decode(
      LauncherConfigFile.self, from: Data(contentsOf: app.appendingPathComponent("Contents/Resources/ClaudeMultiAcc-launcher.json")))
    #expect(config.matches(spec))
  }

  /// R2 item 4: `Contents/Helpers/CloneLauncher` of a downloaded ClaudeMultiAcc.app carries `com.apple.quarantine`,
  /// and the copy must not take it into the clone (the clean step ran before the launcher step).
  @Test func launcherCopyLeavesQuarantineBehind() throws {
    let root = try makeTempDir()
    let app = try MiniBundle.makeSource(in: root, executable: Data("electron".utf8))
    let launcher = root.appendingPathComponent("CloneLauncher")
    try MiniBundle.write(MiniBundle.machOBytes, launcher, mode: 0o755)
    try addQuarantine(launcher)
    #expect(Quarantine.isSet(on: launcher))
    try LauncherInstaller().install(into: app, spec: spec, launcherBinary: launcher, logsDir: logs)
    let main = app.appendingPathComponent("Contents/MacOS/Claude")
    #expect(try Data(contentsOf: main) == MiniBundle.machOBytes)
    #expect(!Quarantine.isSet(on: main))
    #expect(!Quarantine.isSet(on: app.appendingPathComponent("Contents/Resources/ClaudeMultiAcc-launcher.json")))
    #expect(Quarantine.isSet(on: launcher), "the app's own launcher is left as it is")
  }

  @Test func quarantineRemovalIsRecursiveAndToleratesMissingAttribute() throws {
    let root = try makeTempDir()
    let bundle = root.appendingPathComponent("Tile.docktileplugin", isDirectory: true)
    let binary = bundle.appendingPathComponent("Contents/MacOS/Tile")
    try MiniBundle.write(MiniBundle.machOBytes, binary, mode: 0o755)
    let plain = bundle.appendingPathComponent("Contents/Info.plist")
    try MiniBundle.write(Data("<plist/>".utf8), plain)
    try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Current").path, withDestinationPath: "Contents")
    for url in [bundle, binary, binary.deletingLastPathComponent()] { try addQuarantine(url) }
    try Quarantine.remove(from: bundle)
    for url in [bundle, binary, binary.deletingLastPathComponent(), plain] { #expect(!Quarantine.isSet(on: url)) }
    try Quarantine.remove(from: plain)
    #expect(throws: QuarantineError.self) { try Quarantine.remove(from: root.appendingPathComponent("missing")) }
  }

  @Test func missingLauncherThrowsBeforeTouchingTheBundle() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = try MiniBundle.makeSource(in: root)
    let missing = root.appendingPathComponent("nope")
    #expect(throws: BuilderError.launcherMissing(missing.path)) {
      try LauncherInstaller().install(into: app, spec: spec, launcherBinary: missing, logsDir: logs)
    }
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/Claude").path))
  }
}

/// Sets `com.apple.quarantine` the way a browser download does.
func addQuarantine(_ url: URL) throws {
  let value = Array("0083;6710c0de;Safari;F00D".utf8)
  guard setxattr(url.path, Quarantine.attribute, value, value.count, 0, XATTR_NOFOLLOW) == 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
