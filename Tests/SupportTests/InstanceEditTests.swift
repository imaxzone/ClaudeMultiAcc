import Foundation
import Testing
@testable import Support

/// Editing and removing entries of `instances.json` (P4): registry only, never files on disk.
@Suite(.russian) struct InstanceEditTests {
  private func fourStore(_ name: String = #function) throws -> (InstanceStore, Paths, URL) {
    let root = try makeTempDir(name)
    let paths = Paths(home: root.appendingPathComponent("home"), dataDir: root.appendingPathComponent("data"))
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try fixtureText("instances-four.json", root: root).write(to: paths.instancesFile, atomically: true, encoding: .utf8)
    return (InstanceStore(paths: paths), paths, root)
  }

  @Test func editChangesOnlyTheGivenFieldsInPlace() async throws {
    let (store, _, _) = try fourStore()
    let before = try await store.load()
    let edited = try await store.edit(slug: try Slug("work"), InstanceEdit(name: "Claude Job", emails: ["job@example.com"]))
    #expect(edited.name == "Claude Job" && edited.emails == ["job@example.com"])
    let after = try await store.load()
    #expect(after.map(\.slug.raw) == before.map(\.slug.raw))
    let work = try #require(after.first { $0.slug.raw == "work" })
    let old = try #require(before.first { $0.slug.raw == "work" })
    #expect(work == edited)
    #expect(work.badge == old.badge && work.bundleId == old.bundleId && work.appPath == old.appPath)
    #expect(work.profileDir == old.profileDir && work.builtBy == old.builtBy && work.accountUuid == old.accountUuid)
  }

  @Test func editCanSetABadgeAndClearEmails() async throws {
    let (store, _, _) = try fourStore()
    let edited = try await store.edit(slug: try Slug("alt"), InstanceEdit(badge: "alt", emails: []))
    #expect(edited.badge == "alt" && edited.emails.isEmpty)
  }

  @Test func editRejectsInvalidValuesAndChangesNothing() async throws {
    let (store, paths, _) = try fourStore()
    let original = try Data(contentsOf: paths.instancesFile)
    let work = try Slug("work")
    await #expect(throws: InstanceEditError.invalid([.emptyName])) {
      _ = try await store.edit(slug: work, InstanceEdit(name: "  "))
    }
    await #expect(throws: InstanceEditError.invalid([.badBadge("TOOLONG"), .badEmail("nope")])) {
      _ = try await store.edit(slug: work, InstanceEdit(badge: "TOOLONG", emails: ["ok@example.com", "nope"]))
    }
    await #expect(throws: InstanceEditError.invalid([.nameTooLong(41)])) {
      _ = try await store.edit(slug: work, InstanceEdit(name: String(repeating: "n", count: 41)))
    }
    await #expect(throws: InstanceEditError.notFound("nope")) {
      _ = try await store.edit(slug: try Slug("nope"), InstanceEdit(name: "X"))
    }
    #expect(try Data(contentsOf: paths.instancesFile) == original)
  }

  @Test func removeEntryDropsOnlyTheRegistryEntry() async throws {
    let (store, paths, root) = try fourStore()
    let app = root.appendingPathComponent("Applications/Claude Work.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    let removed = try await store.removeEntry(slug: try Slug("work"))
    #expect(removed.slug.raw == "work")
    #expect(try await store.load().map(\.slug.raw) == ["main", "second", "alt"])
    #expect(FileManager.default.fileExists(atPath: app.path))
    #expect(removed.leftOnDisk(paths: paths) == [try #require(removed.appPath)])
  }

  /// The official app entry (`main`) is the one entry that can never be removed (by kind, not by slug: G20).
  @Test func removeEntryRefusesTheOfficialApp() async throws {
    let (store, _, _) = try fourStore()
    await #expect(throws: InstanceEditError.officialNotRemovable("main")) {
      _ = try await store.removeEntry(slug: try Slug("main"))
    }
    #expect(try await store.load().count == 4)
    await #expect(throws: InstanceEditError.notFound("nope")) {
      _ = try await store.removeEntry(slug: try Slug("nope"))
    }
  }

  @Test func errorsHaveRussianMessagesAndEnglishDescriptions() {
    let errors: [InstanceEditError] = [
      .notFound("x"), .officialNotRemovable("main"), .invalid([.emptyName, .nameTooLong(41), .badBadge(""), .badEmail("x")]),
    ]
    for error in errors {
      #expect(error.message.range(of: "[А-Яа-я]", options: .regularExpression) != nil)
      #expect(error.description.range(of: "[А-Яа-я]", options: .regularExpression) == nil)
    }
  }
}
