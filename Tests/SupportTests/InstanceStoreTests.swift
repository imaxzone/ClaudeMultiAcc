import Foundation
import Testing
@testable import Support

@Suite struct InstanceStoreTests {
  private func makeStore(_ name: String = #function) throws -> (InstanceStore, Paths, URL) {
    let root = try makeTempDir(name)
    let paths = Paths(home: root.appendingPathComponent("home"), dataDir: root.appendingPathComponent("data"))
    return (InstanceStore(paths: paths), paths, root)
  }

  private func writeFour(_ paths: Paths, root: URL) throws {
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try fixtureText("instances-four.json", root: root).write(to: paths.instancesFile, atomically: true, encoding: .utf8)
  }

  private func instance(_ slug: String, bundleId: String? = nil, appPath: String? = nil, profileDir: String? = nil,
                        name: String = "X") throws -> Instance {
    Instance(slug: try Slug(slug), name: name, kind: .clone, bundleId: bundleId, appPath: appPath, profileDir: profileDir)
  }

  /// A new user starts with only the official Claude: no accounts or organisations of anyone else (S1, R2).
  @Test func seedsHoldOnlyTheOfficialClaude() throws {
    let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)
    let seeds = InstanceSeeds.seeds(home: home)
    #expect(seeds.map(\.slug.raw) == ["main"])
    let main = try #require(seeds.first)
    #expect(main.kind == .official)
    #expect(main.name == "Claude")
    #expect(main.bundleId == "com.anthropic.claudefordesktop")
    #expect(main.appPath == "/Applications/Claude.app")
    #expect(main.profileDir == "/Users/u/Library/Application Support/Claude")
    #expect(main.accountUuid == nil && main.orgUuid == nil)
    #expect(main.cliConfigDir == nil && main.badge == nil && main.builtBy == "vendor")
    #expect(main.emails.isEmpty && main.pendingBuild == nil)
  }

  @Test func seedsOnlyWhenMissingWithMode0600() async throws {
    let (store, paths, _) = try makeStore()
    let loaded = try await store.loadOrSeed()
    #expect(loaded == InstanceSeeds.seeds(home: paths.home))
    #expect(try posixPermissions(paths.instancesFile) == 0o600)
    let reloaded = try await InstanceStore(paths: paths).loadOrSeed()
    #expect(reloaded == loaded)
  }

  @Test func loadWithoutSeedingDoesNotWrite() async throws {
    let (store, paths, _) = try makeStore()
    let loaded = try await store.load()
    #expect(loaded.count == 1)
    #expect(!FileManager.default.fileExists(atPath: paths.instancesFile.path))
  }

  @Test func corruptFileIsNotOverwritten() async throws {
    let (store, paths, _) = try makeStore()
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try Data("{\"schemaVersion\":1,".utf8).write(to: paths.instancesFile)
    await #expect(throws: InstanceStoreError.corrupt(path: paths.instancesFile.path)) {
      _ = try await store.loadOrSeed()
    }
    await #expect(throws: InstanceStoreError.corrupt(path: paths.instancesFile.path)) {
      _ = try await store.upsert(try instance("new"))
    }
    #expect(try String(contentsOf: paths.instancesFile, encoding: .utf8) == "{\"schemaVersion\":1,")
  }

  @Test func loadsFourInstancesInOrder() async throws {
    let (store, paths, root) = try makeStore()
    try writeFour(paths, root: root)
    let list = try await store.loadOrSeed()
    #expect(list.map(\.slug.raw) == ["main", "second", "work", "alt"])
    #expect(list[2].bundleId == "com.imaxzone.claude.work")
    #expect(list[2].orgUuid == nil)
    #expect(list[3].profileDir == nil)
    #expect(list[1].profileDir == root.path + "/profiles/second")
  }

  @Test func upsertReplacesInPlaceOrAppends() async throws {
    let (store, paths, root) = try makeStore()
    try writeFour(paths, root: root)
    let four = try await store.loadOrSeed()
    let renamed = Instance(slug: four[1].slug, name: "Renamed", kind: .clone, bundleId: four[1].bundleId)
    let replaced = try await store.upsert(renamed)
    #expect(replaced.map(\.slug.raw) == ["main", "second", "work", "alt"])
    #expect(replaced[1].name == "Renamed")
    let appended = try await store.upsert(try instance("five"))
    #expect(appended.map(\.slug.raw) == ["main", "second", "work", "alt", "five"])
    #expect(try await InstanceStore(paths: paths).loadOrSeed() == appended)
  }

  @Test func removeAndMove() async throws {
    let (store, paths, root) = try makeStore()
    try writeFour(paths, root: root)
    _ = try await store.loadOrSeed()
    let moved = try await store.move(slug: try Slug("alt"), to: 0)
    #expect(moved.map(\.slug.raw) == ["alt", "main", "second", "work"])
    let clamped = try await store.move(slug: try Slug("alt"), to: 99)
    #expect(clamped.map(\.slug.raw) == ["main", "second", "work", "alt"])
    let removed = try await store.remove(slug: try Slug("second"))
    #expect(removed.map(\.slug.raw) == ["main", "work", "alt"])
    await #expect(throws: InstanceStoreError.notFound("nope")) {
      _ = try await store.remove(slug: try Slug("nope"))
    }
    await #expect(throws: InstanceStoreError.notFound("nope")) {
      _ = try await store.move(slug: try Slug("nope"), to: 0)
    }
  }

  @Test func validateNewAgainstFour() async throws {
    let (store, paths, root) = try makeStore()
    try writeFour(paths, root: root)
    let four = try await store.loadOrSeed()
    #expect(await store.validateNew(try instance("fresh", bundleId: "com.imaxzone.claude.fresh")).isEmpty)
    let clash = Instance(slug: try Slug("work"), name: "  ", kind: .clone, bundleId: four[0].bundleId,
                         appPath: four[1].appPath, profileDir: four[2].profileDir)
    let errors = await store.validateNew(clash)
    #expect(errors == [
      .duplicateSlug("work"), .duplicateBundleId("com.anthropic.claudefordesktop"),
      .duplicateAppPath(root.path + "/Applications/Claude 2nd.app"),
      .duplicateProfileDir(root.path + "/profiles/work"), .emptyName,
    ])
  }

  /// A corrupt list must not validate as "no duplicates": the caller gets a distinct error and shows it.
  @Test func validateNewReportsACorruptStore() async throws {
    let (store, paths, _) = try makeStore()
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: paths.instancesFile)
    let errors = await store.validateNew(try instance("fresh", bundleId: "com.imaxzone.claude.fresh"))
    #expect(errors == [.storeCorrupt(paths.instancesFile.path)])
    #expect(try String(contentsOf: paths.instancesFile, encoding: .utf8) == "{broken")
  }

  @Test func oneAndNineInstanceLists() async throws {
    let (store, paths, _) = try makeStore()
    let one = [try instance("solo", bundleId: "com.imaxzone.claude.solo")]
    try await store.save(one)
    #expect(try await store.loadOrSeed() == one)
    let nine = try (1...9).map { try instance("acc\($0)", bundleId: "com.imaxzone.claude.acc\($0)") }
    try await store.save(nine)
    let loaded = try await InstanceStore(paths: paths).loadOrSeed()
    #expect(loaded.map(\.slug.raw) == (1...9).map { "acc\($0)" })
    let moved = try await store.move(slug: try Slug("acc1"), to: 8)
    #expect(moved.last?.slug.raw == "acc1")
    #expect(moved.count == 9)
  }

  @Test func encodesExplicitNullsAndCamelCase() async throws {
    let (store, paths, _) = try makeStore()
    try await store.save([try instance("solo")])
    let text = try String(contentsOf: paths.instancesFile, encoding: .utf8)
    #expect(text.contains("\"schemaVersion\" : 1"))
    #expect(text.contains("\"cliConfigDir\" : null"))
    #expect(text.contains("\"pendingBuild\" : null"))
  }

  /// Files written while Remote Control existed carry `rcDirs`: the key is ignored on load and gone after a save.
  @Test func legacyRcDirsAreIgnoredAndDroppedOnSave() async throws {
    let (store, paths, root) = try makeStore()
    try writeFour(paths, root: root)
    let legacy = try String(contentsOf: paths.instancesFile, encoding: .utf8)
      .replacingOccurrences(of: #""rcDirs": []"#, with: #""rcDirs": ["/Users/u/ClaudeRemote/x"]"#)
    #expect(legacy.contains("ClaudeRemote"))
    try legacy.write(to: paths.instancesFile, atomically: true, encoding: .utf8)
    let loaded = try await store.load()
    #expect(loaded.map(\.slug.raw) == ["main", "second", "work", "alt"])
    try await store.save(loaded)
    let text = try String(contentsOf: paths.instancesFile, encoding: .utf8)
    #expect(!text.contains("rcDirs"))
    #expect(try await store.load() == loaded)
  }
}
