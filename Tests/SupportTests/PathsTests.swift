import Foundation
import Testing
@testable import Support

@Suite struct PathsTests {
  let home = URL(fileURLWithPath: "/tmp/fakehome", isDirectory: true)

  @Test func defaultsFollowG1() {
    let p = Paths(home: home)
    #expect(p.dataDir.path == "/tmp/fakehome/Library/Application Support/ClaudeMultiAcc")
    #expect(p.logsDir.path == "/tmp/fakehome/Library/Logs/ClaudeMultiAcc")
    let d = p.dataDir.path
    #expect(p.instancesFile.path == d + "/instances.json")
    #expect(p.settingsFile.path == d + "/settings.json")
    #expect(p.stagingDir.path == d + "/staging")
    #expect(p.backupDir.path == d + "/backup")
    #expect(p.signingDir.path == d + "/signing")
    #expect(p.requirementFile.path == d + "/signing/requirement.txt")
    #expect(p.identityFile.path == d + "/signing/identity.json")
    #expect(p.cliAccountsRoot.path == "/tmp/fakehome/.claude-accounts")
  }

  @Test func explicitDirsOverrideDefaults() {
    let p = Paths(home: home, dataDir: URL(fileURLWithPath: "/x/data"), logsDir: URL(fileURLWithPath: "/x/logs"))
    #expect(p.dataDir.path == "/x/data")
    #expect(p.logsDir.path == "/x/logs")
    #expect(p.settingsFile.path == "/x/data/settings.json")
  }

  @Test func liveHonoursEnvironmentOverrides() {
    let p = Paths.live(environment: [
      "CMACC_HOME": "/e/home", "CMACC_DATA_DIR": "/e/data", "CMACC_LOGS_DIR": "/e/logs",
    ])
    #expect(p.home.path == "/e/home")
    #expect(p.dataDir.path == "/e/data")
    #expect(p.logsDir.path == "/e/logs")
  }

  @Test func liveHomeOnlyDerivesDefaults() {
    let p = Paths.live(environment: ["CMACC_HOME": "/e/home"])
    #expect(p.dataDir.path == "/e/home/Library/Application Support/ClaudeMultiAcc")
    #expect(p.logsDir.path == "/e/home/Library/Logs/ClaudeMultiAcc")
  }

  @Test func liveWithoutOverridesUsesUserHome() {
    let p = Paths.live(environment: [:])
    #expect(p.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
  }

  @Test func ensureDataDirsCreatesDirsWithModes() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let p = Paths(home: root)
    try p.ensureDataDirs()
    try p.ensureDataDirs() // idempotent
    #expect(try posixPermissions(p.dataDir) == 0o700)
    #expect(try posixPermissions(p.signingDir) == 0o700)
    #expect(try posixPermissions(p.logsDir) == 0o700)
    for dir in [p.stagingDir, p.backupDir] {
      var isDir: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
    }
  }
}
