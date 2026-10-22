import Foundation
import LinkRouter
import Support
import Testing
@testable import cmacc

/// `cmacc route --dry-run` against a temporary registry; it never delivers a link or changes the handler.
@Suite struct RouteCommandTests {
  @Test(arguments: [
    ["claude://claude.ai/new"], ["--dry-run"], ["--dry-run", "a", "b"], ["--dry-run", "--verbose"], [],
  ])
  func rejectsBadUsage(args: [String]) {
    #expect(RouteCommand.parse(args) == nil)
  }

  @Test func parsesTheLinkAndJson() throws {
    let parsed = try #require(RouteCommand.parse(["--json", "--dry-run", "claude://claude.ai/new"]))
    #expect(parsed.url.absoluteString == "claude://claude.ai/new")
    #expect(parsed.json)
    #expect(RouteCommand.parse(["--dry-run", "claude://x"])?.json == false)
  }

  @Test func reportUsesTheRegistryAndRunningClones() async throws {
    let root = TempDirs.register(FileManager.default.temporaryDirectory
      .appendingPathComponent("cmacc-route-tests-\(UUID().uuidString)", isDirectory: true))
    let paths = Paths(home: root.appendingPathComponent("home"), dataDir: root.appendingPathComponent("data"))
    let clone = Instance(
      slug: try Slug("lab"), name: "Claude Lab", kind: .clone, bundleId: "com.example.lab",
      appPath: root.appendingPathComponent("Claude Lab.app").path, profileDir: root.appendingPathComponent("lab").path)
    let official = Instance(
      slug: try Slug("main"), name: "Claude", kind: .official, bundleId: "com.anthropic.claudefordesktop",
      appPath: root.appendingPathComponent("Claude.app").path, profileDir: root.appendingPathComponent("main").path)
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try await InstanceStore(paths: paths).save([official, clone])
    let magic = try #require(URL(string: "claude://claude.ai/magic-link#0123456789abcdef0123456789abcdef:eEBleGFtcGxlLmNvbQ=="))

    let waiting = try await RouteCommand(paths: { paths }, runningBundleIds: { ["com.example.lab"] }).report(for: magic)
    #expect(waiting.decision == "clone" && waiting.target == "lab")
    let idle = try await RouteCommand(paths: { paths }, runningBundleIds: { [] }).report(for: magic)
    #expect(idle.decision == "official" && idle.target == "Claude")
    #expect(try await RouteCommand(paths: { paths }, runningBundleIds: { [] }).run(["--dry-run", "claude://x", "--json"])
      == ExitCode.success)
    #expect(try await RouteCommand(paths: { paths }).run(["claude://x"]) == ExitCode.usage)
  }
}
