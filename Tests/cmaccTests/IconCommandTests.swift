import Foundation
import InstanceBuilder
import Support
import Testing
@testable import cmacc

/// `cmacc instance icon <slug>` is retired: it only explains (the badge is baked into `electron.icns` at build time)
/// and never writes anything. Runs against a temporary registry only.
@Suite struct IconCommandTests {
  struct Fixture {
    let paths: Paths
    let apps: URL
    let work: URL
  }

  /// main (official), alt (cliOnly), work (clone with an old Finder custom icon), bare (clone without a badge).
  private func fixture() async throws -> Fixture {
    let root = TempDirs.register(FileManager.default.temporaryDirectory
      .appendingPathComponent("cmacc-icon-tests-\(UUID().uuidString)", isDirectory: true))
    let paths = Paths(home: root.appendingPathComponent("home"), dataDir: root.appendingPathComponent("data"))
    let apps = root.appendingPathComponent("Applications", isDirectory: true)
    let work = apps.appendingPathComponent("Claude Work.app", isDirectory: true)
    let bare = apps.appendingPathComponent("Claude Bare.app", isDirectory: true)
    for app in [work, bare] {
      try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    }
    try Data().write(to: work.appendingPathComponent(CustomIconCheck.iconFile))
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try await InstanceStore(paths: paths).save([
      Instance(slug: try Slug("main"), name: "Claude", kind: .official, appPath: apps.appendingPathComponent("Claude.app").path),
      Instance(slug: try Slug("alt"), name: "Alt", kind: .cliOnly),
      Instance(slug: try Slug("work"), name: "Claude Work", kind: .clone, appPath: work.path, badge: "W", builtBy: "cmacc"),
      Instance(slug: try Slug("bare"), name: "Claude Bare", kind: .clone, appPath: bare.path),
    ])
    return Fixture(paths: paths, apps: apps, work: work)
  }

  private func run(_ f: Fixture, _ args: [String]) async throws -> Int32 {
    try await IconCommand(paths: { f.paths }).run(try #require(InstanceOptions.parse(args)))
  }

  /// Nothing is applied, so a known instance still exits with failure; the bundle is left exactly as it was.
  @Test func explainsAndWritesNothing() async throws {
    let f = try await fixture()
    let before = try FileManager.default.contentsOfDirectory(atPath: f.work.path).sorted()
    for args in [["work"], ["work", "--label", "Job"], ["bare"], ["main"], ["alt"]] {
      #expect(try await run(f, args) == ExitCode.failure, "\(args)")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.work.path).sorted() == before)
  }

  @Test func refusesUnknownInstancesAndBadUsage() async throws {
    let f = try await fixture()
    #expect(try await run(f, ["nope"]) == ExitCode.failure)
    #expect(try await run(f, []) == ExitCode.usage)
    #expect(try await run(f, ["work", "extra"]) == ExitCode.usage)
    #expect(try await run(f, ["Bad_Slug"]) == ExitCode.usage)
  }

  @Test func theExplanationNamesTheBadgeAndTheWayToChangeIt() async throws {
    let f = try await fixture()
    let instances = try await InstanceStore(paths: f.paths).load()
    func text(_ slug: String) throws -> String {
      IconCommand.explanation(for: try #require(instances.first { $0.slug.raw == slug }))
    }
    let work = try text("work")
    #expect(work.contains("electron.icns") && work.contains("«W»") && work.contains("rebuil"), "\(work)")
    #expect(work.contains("old Finder custom icon"), "\(work)")
    let bare = try text("bare")
    #expect(bare.contains("no badge") && !bare.contains("old Finder custom icon"), "\(bare)")
    #expect(try text("main").contains("not a clone"))
    #expect(try text("alt").contains("not a clone"))
  }

  @Test func parsesTheLabelOption() throws {
    let options = try #require(InstanceOptions.parse(["icon", "work", "--label", "Job"]))
    #expect(options.positional == ["icon", "work"] && options.values["--label"] == "Job")
    #expect(InstanceOptions.parse(["icon", "work", "--label"]) == nil)
  }

  @Test func instanceCommandRoutesIconAndNeedsASlug() async throws {
    #expect(InstanceCommand.usageText.contains("cmacc instance icon <slug>"))
    #expect(try await InstanceCommand().run(["icon"]) == ExitCode.usage)
  }
}
