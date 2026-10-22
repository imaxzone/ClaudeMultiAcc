import Foundation
import Testing
@testable import CloneLauncher

@Suite struct LaunchPlanTests {
  let config = LauncherConfig(
    schemaVersion: 1, slug: "stagetest", bundleId: "com.imaxzone.claude.stagetest",
    profileDir: "/Users/u/Library/Application Support/ClaudeProfiles/stagetest", realExecutable: "Claude.real",
    logFile: "/Users/u/Library/Logs/ClaudeMultiAcc/launcher-stagetest.log")

  @Test func decodesBriefSchema() throws {
    let json = """
      {"schemaVersion":1,"slug":"stagetest","bundleId":"com.imaxzone.claude.stagetest",\
      "profileDir":"/Users/u/Library/Application Support/ClaudeProfiles/stagetest","realExecutable":"Claude.real",\
      "logFile":"/Users/u/Library/Logs/ClaudeMultiAcc/launcher-stagetest.log"}
      """
    #expect(try LauncherConfig.decode(Data(json.utf8)) == config)
  }

  @Test func rejectsUnknownSchemaAndBadExecutable() {
    let future = #"{"schemaVersion":2,"slug":"a","bundleId":"b","profileDir":"/p","realExecutable":"Claude.real","logFile":"/l"}"#
    #expect(throws: LauncherConfigError.self) { try LauncherConfig.decode(Data(future.utf8)) }
    let escape = #"{"schemaVersion":1,"slug":"a","bundleId":"b","profileDir":"/p","realExecutable":"../x","logFile":"/l"}"#
    #expect(throws: LauncherConfigError.self) { try LauncherConfig.decode(Data(escape.utf8)) }
    let relative = #"{"schemaVersion":1,"slug":"a","bundleId":"b","profileDir":"p","realExecutable":"Claude.real","logFile":"/l"}"#
    #expect(throws: LauncherConfigError.self) { try LauncherConfig.decode(Data(relative.utf8)) }
  }

  @Test func plansRealExecutableWithProfileFirst() {
    let plan = LaunchPlanner.plan(config: config, bundlePath: "/Apps/Claude Stage.app", argv: ["/Apps/Claude Stage.app/Contents/MacOS/Claude"])
    #expect(plan.executable == "/Apps/Claude Stage.app/Contents/MacOS/Claude.real")
    #expect(plan.arguments == [
      "/Apps/Claude Stage.app/Contents/MacOS/Claude.real",
      "--user-data-dir=/Users/u/Library/Application Support/ClaudeProfiles/stagetest",
    ])
  }

  @Test func filtersUserDataDirAndPsnButKeepsOthers() {
    let argv = ["x", "-psn_0_12345", "--user-data-dir=/evil", "claude://open?q=a b", "--flag", "--user-data-dir=/x y"]
    let plan = LaunchPlanner.plan(config: config, bundlePath: "/A.app", argv: argv)
    #expect(plan.arguments == [
      "/A.app/Contents/MacOS/Claude.real",
      "--user-data-dir=/Users/u/Library/Application Support/ClaudeProfiles/stagetest",
      "claude://open?q=a b", "--flag",
    ])
  }

  @Test func emptyArgvStillPlans() {
    let plan = LaunchPlanner.plan(config: config, bundlePath: "/A.app", argv: [])
    #expect(plan.arguments.count == 2)
  }

  @Test func logLineHasTimePidVersionAndProfile() {
    let line = LaunchLog.line(date: Date(timeIntervalSince1970: 0), pid: 42, version: "1.2.3", profileDir: "/p q")
    #expect(line == "1970-01-01T00:00:00Z pid=42 version=1.2.3 profile=/p q\n")
  }
}
