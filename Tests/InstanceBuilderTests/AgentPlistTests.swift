import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct AgentPlistTests {
  static let app = URL(fileURLWithPath: "/Users/u/Applications/ClaudeMultiAcc.app", isDirectory: true)
  static let logs = URL(fileURLWithPath: "/Users/u/Library/Logs/ClaudeMultiAcc", isDirectory: true)

  /// Launch at login is the menu switch (SMAppService) now: no plist is generated for the retired `app` kind.
  @Test func theRetiredAppAgentHasNoPlist() {
    #expect(AgentKind.app.isRetired)
    #expect(!AgentKind.updateWatcher.isRetired)
    #expect(AgentPlist.make(kind: .app, appPath: Self.app, logsDir: Self.logs) == nil)
  }

  @Test func updateWatcherAgentRunsTheHelperOnOfficialChangesAndHourly() throws {
    let dict = try plistDict(try #require(AgentPlist.make(kind: .updateWatcher, appPath: Self.app, logsDir: Self.logs)))
    #expect(NSDictionary(dictionary: dict).isEqual(to: [
      "Label": "com.imaxzone.ClaudeMultiAcc.update-watcher",
      "ProgramArguments": [
        "/Users/u/Applications/ClaudeMultiAcc.app/Contents/Helpers/cmacc", "update", "check", "--apply-when-idle",
      ],
      "WatchPaths": ["/Applications/Claude.app/Contents/Info.plist"],
      "StartInterval": 3600,
      "RunAtLoad": true,
      "StandardOutPath": "/Users/u/Library/Logs/ClaudeMultiAcc/agent-update.log",
      "StandardErrorPath": "/Users/u/Library/Logs/ClaudeMultiAcc/agent-update.log",
    ] as [String: Any]))
  }

  @Test func xmlPassesPlutilLint() async throws {
    let data = try #require(AgentPlist.make(kind: .updateWatcher, appPath: Self.app, logsDir: Self.logs))
    #expect(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"))
    let result = try await SystemProcessRunner().run(ProcessRequest(
      executable: URL(fileURLWithPath: "/usr/bin/plutil"), arguments: ["-lint", "-"], timeout: .seconds(30), stdin: data))
    #expect(result.exitCode == 0, "\(result.stdoutText) \(result.stderrText)")
  }

  @Test func kindsAndInstallPaths() {
    #expect(AgentKind(argument: "app") == .app)
    #expect(AgentKind(argument: "update-watcher") == .updateWatcher)
    #expect(AgentKind(argument: "other") == nil)
    let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)
    #expect(AgentPlist.installURL(kind: .updateWatcher, home: home).path
      == "/Users/u/Library/LaunchAgents/com.imaxzone.ClaudeMultiAcc.update-watcher.plist")
    // Where an old `--kind app` agent lives; the app trashes it when the user flips the menu switch.
    #expect(AgentPlist.installURL(kind: .app, home: home).path
      == "/Users/u/Library/LaunchAgents/com.imaxzone.ClaudeMultiAcc.plist")
  }
}
