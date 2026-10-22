import Foundation
import Support
import Synchronization
import Testing
@testable import cmacc

/// `cmacc instances remove|edit` against a temporary registry only (never the real one).
@Suite struct InstancesCommandTests {
  private func paths() throws -> Paths {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("cmacc-cli-tests-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(home: root.appendingPathComponent("home"), dataDir: root.appendingPathComponent("data"))
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    _ = TempDirs.register(root)
    return paths
  }

  @Test func editParsesEveryOption() throws {
    let parsed = try #require(EditOptions.parse(["alt", "--badge", "alt", "--emails", "a@x.io, b@y.org", "--name", "Alt"]))
    #expect(parsed.slug.raw == "alt")
    #expect(parsed.edit == InstanceEdit(name: "Alt", badge: "alt", emails: ["a@x.io", "b@y.org"]))
    #expect(EditOptions.parse(["alt", "--clear-emails"])?.edit == InstanceEdit(emails: []))
  }

  @Test(arguments: [
    ["alt"], ["--name", "x"], ["alt", "--emails", "a@x.io", "--clear-emails"], ["alt", "--name", "--badge"],
    ["alt", "extra", "--name", "x"], ["Bad_Slug", "--name", "x"],
  ])
  func editRejectsBadUsage(args: [String]) {
    #expect(EditOptions.parse(args) == nil)
  }

  @Test func removeAndEditChangeOnlyTheTemporaryRegistry() async throws {
    let paths = try paths()
    let second = Instance(slug: try Slug("second"), name: "Claude 2nd", kind: .clone,
                          bundleId: "com.anthropic.claudefordesktop2", appPath: "/Applications/Claude 2nd.app",
                          badge: "2nd", builtBy: "legacy-script")
    let alt = Instance(slug: try Slug("alt"), name: "Claude (alt CLI)", kind: .cliOnly,
                       cliConfigDir: paths.home.appendingPathComponent(".claude-alt").path)
    try await InstanceStore(paths: paths).save(InstanceSeeds.seeds(home: paths.home) + [second, alt])
    let command = InstancesCommand(paths: { paths })
    #expect(try await command.run(["edit", "alt", "--badge", "alt", "--emails", "alt@example.com"]) == ExitCode.success)
    let edited = try #require(try await InstanceStore(paths: paths).load().first { $0.slug.raw == "alt" })
    #expect(edited.badge == "alt" && edited.emails == ["alt@example.com"])
    #expect(try await command.run(["remove", "second", "--yes"]) == ExitCode.success)
    #expect(try await InstanceStore(paths: paths).load().map(\.slug.raw) == ["main", "alt"])
    await #expect(throws: InstanceEditError.officialNotRemovable("main")) {
      _ = try await command.run(["remove", "main", "--yes"])
    }
    #expect(try await command.run(["remove"]) == ExitCode.usage)
    #expect(try await command.run(["frobnicate"]) == ExitCode.usage)
  }
}

/// Temp dirs of this target, removed at exit (S12).
enum TempDirs {
  private static let dirs = Mutex<[URL]>([])
  private static let cleanupInstalled: Void = { atexit { TempDirs.removeAll() } }()

  static func register(_ url: URL) -> URL {
    _ = cleanupInstalled
    dirs.withLock { $0.append(url) }
    return url
  }

  static func removeAll() {
    for url in dirs.withLock({ $0 }) { try? FileManager.default.removeItem(at: url) }
  }
}
