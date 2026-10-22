import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// `remove(slug:mode:)` with crafted or corrupted `instances.json` entries and paths swapped after the check: nothing
/// outside the clone's own app, profile, backups and staging builds ever moves.
@Suite(.russian) struct InstanceRemoverPolicyTests {
  private let allSlugs = ["main", "second", "mv2", "work", "alt"]
  private let userFiles = ["SystemApplications/Xcode.app/Contents/Info.plist", "Documents/notes.txt", ".ssh/id_ed25519",
                           "Applications/ClaudeMultiAcc.app/Contents/Info.plist", "Applications/Claude.app/Contents/Info.plist"]

  /// Adds the clone `evil` with a valid-looking bundle id and the given app and profile (relative to the home).
  private func addEvil(_ f: RemovalFixture, app: String, profile: String) async throws {
    _ = try await f.store.upsert(Instance(
      slug: testSlug("evil"), name: "Claude evil", kind: .clone, bundleId: "com.imaxzone.claude.evil",
      appPath: f.root.appendingPathComponent(app).path, profileDir: f.root.appendingPathComponent(profile).path,
      builtBy: "cmacc"))
  }

  /// Finding 1's entries (Xcode, Documents, ~/.ssh, ClaudeMultiAcc itself, a letter-case variant of the official app).
  @Test(arguments: [
    ("SystemApplications/Xcode.app", "Library/Application Support/ClaudeProfiles/evil"),
    ("Applications/Claude evil.app", "Documents"),
    ("Applications/Claude evil.app", ".ssh"),
    ("Applications/ClaudeMultiAcc.app", "Library/Application Support/ClaudeProfiles/evil"),
    ("applications/CLAUDE.app", "Library/Application Support/ClaudeProfiles/evil"),
    ("Documents", "Library/Application Support/ClaudeProfiles/evil"),
  ])
  func craftedEntriesMoveNothing(app: String, profile: String) async throws {
    let f = try await RemovalFixture()
    try await addEvil(f, app: app, profile: profile)
    await #expect(throws: RemovalError.self) { try await f.remover.target(slug: "evil") }
    let report = await f.remover.remove(slug: "evil", mode: .everything)
    #expect(report.changedNothing && report.problems.count == 1 && report.problems[0].hasSuffix("ничего не изменено"))
    #expect(f.events.all.isEmpty, "no lock, quit or trash: \(f.events.all)")
    for file in userFiles { #expect(f.exists(file), "\(file) must stay") }
    #expect(try await f.slugs() == allSlugs + ["evil"])
    #expect(try f.log().contains("remove evil: refused"))
  }

  @Test func aSymlinkedProfileMovesNothing() async throws {
    let f = try await RemovalFixture()
    let profile = f.root.appendingPathComponent(RemovalFixture.mv2Profile)
    try FileManager.default.removeItem(at: profile)
    try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: f.root.appendingPathComponent("Documents"))
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(report.changedNothing && f.events.all.isEmpty)
    #expect(report.problems == ["«Claude mv2»: ~/\(RemovalFixture.mv2Profile) — ссылка или файл, а не папка профиля — "
      + "ничего не изменено"])
    #expect(f.exists(RemovalFixture.mv2App) && f.exists("Documents/notes.txt"))
    #expect(try await f.slugs() == allSlugs)
  }

  /// The profile is swapped for a link to ~/Documents after the check: the app and its copies go, the link stays.
  @Test func aProfileSwappedAfterTheCheckStays() async throws {
    var knobs = RemovalFixture.Knobs(running: true)
    knobs.whileQuitting = { root in
      let profile = root.appendingPathComponent(RemovalFixture.mv2Profile)
      try? FileManager.default.moveItem(at: profile, to: root.appendingPathComponent("outside/mv2-profile"))
      try? FileManager.default.createSymbolicLink(at: profile, withDestinationURL: root.appendingPathComponent("Documents"))
    }
    let f = try await RemovalFixture(knobs)
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(!f.events.contains("trash(\(RemovalFixture.mv2Profile))"))
    #expect(report.trashed.map { RemovalFixture.relative($0, root: f.root) }
      == [RemovalFixture.mv2App] + RemovalFixture.backups + [RemovalFixture.staging])
    #expect(report.notTrashed.map { RemovalFixture.relative($0, root: f.root) } == [RemovalFixture.mv2Profile])
    #expect(report.problems.contains { $0.hasPrefix("Не перемещено: вход, настройки и кэш") && $0.contains("изменилось") })
    #expect(f.exists("Documents/notes.txt") && f.exists(RemovalFixture.mv2Profile))
    #expect(try f.log().contains("changed since the check"))
  }

  /// The app is swapped after the check: nothing moves and the entry stays.
  @Test func anAppSwappedAfterTheCheckStopsEverything() async throws {
    var knobs = RemovalFixture.Knobs(running: true)
    knobs.whileQuitting = { root in
      let app = root.appendingPathComponent(RemovalFixture.mv2App)
      try? FileManager.default.moveItem(at: app, to: root.appendingPathComponent("outside/real.app"))
      try? FileManager.default.createSymbolicLink(at: app, withDestinationURL: root.appendingPathComponent("SystemApplications/Xcode.app"))
    }
    let f = try await RemovalFixture(knobs)
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(report.changedNothing && !f.events.all.contains { $0.hasPrefix("trash(") })
    #expect(report.problems == ["«Claude mv2»: ~/\(RemovalFixture.mv2App) изменилось после проверки — ничего не изменено"])
    #expect(f.exists("SystemApplications/Xcode.app/Contents/Info.plist") && f.exists(RemovalFixture.mv2Profile))
    #expect(try await f.slugs() == allSlugs)
  }

  /// Something appears where nothing was at check time: it is not taken for the clone's.
  @Test func aProfileCreatedAfterTheCheckStays() async throws {
    var knobs = RemovalFixture.Knobs(running: true)
    knobs.whileQuitting = { root in
      let profile = root.appendingPathComponent(RemovalFixture.mv2Profile)
      try? FileManager.default.removeItem(at: profile)
      try? FileManager.default.createSymbolicLink(at: profile, withDestinationURL: root.appendingPathComponent(".ssh"))
    }
    let f = try await RemovalFixture(knobs)
    try FileManager.default.removeItem(at: f.root.appendingPathComponent(RemovalFixture.mv2Profile))
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(report.notTrashed.map { RemovalFixture.relative($0, root: f.root) } == [RemovalFixture.mv2Profile])
    #expect(f.exists(".ssh/id_ed25519"))
  }
}
