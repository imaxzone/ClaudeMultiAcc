import Foundation
import InstanceBuilder
import Support
import Testing
@testable import cmacc

/// `cmacc agent` against a temporary home only (never the real `~/Library/LaunchAgents`).
@Suite struct AgentCommandTests {
  private func paths() throws -> Paths {
    let root = TempDirs.register(FileManager.default.temporaryDirectory
      .appendingPathComponent("cmacc-agent-tests-\(UUID().uuidString)", isDirectory: true))
    let paths = Paths(home: root.appendingPathComponent("home"))
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    return paths
  }

  @Test func theRetiredAppKindPointsToTheMenuSwitchAndWritesNothing() async throws {
    let paths = try paths()
    let command = AgentCommand(paths: { paths })
    #expect(AgentCommand.retiredAppNotice.contains("“Open at Login”"))
    #expect(try await command.run(["install", "--kind", "app", "--yes"]) == ExitCode.success)
    #expect(try await command.run(["print", "--kind", "app"]) == ExitCode.success)
    let agents = paths.home.appendingPathComponent("Library/LaunchAgents")
    #expect(!FileManager.default.fileExists(atPath: agents.path))
  }

  @Test func theUpdateWatcherStillInstalls() async throws {
    let paths = try paths()
    let command = AgentCommand(paths: { paths })
    #expect(try await command.run(["install", "--kind", "update-watcher", "--yes"]) == ExitCode.success)
    let target = AgentPlist.installURL(kind: .updateWatcher, home: paths.home)
    let written = try Data(contentsOf: target)
    #expect(written == AgentPlist.make(kind: .updateWatcher, appPath: OwnApp.live(home: paths.home), logsDir: paths.logsDir))
  }

  @Test(arguments: [[], ["install"], ["print", "--kind", "other"], ["remove", "--kind", "app"], ["print", "--kind"]])
  func rejectsBadUsage(args: [String]) async throws {
    let paths = try paths()
    #expect(try await AgentCommand(paths: { paths }).run(args) == ExitCode.usage)
  }
}
