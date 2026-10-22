import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// A FakeCloneBuilder that runs `during` while it builds: the moment between the check and the swap or rename.
struct InterruptingBuilder: CloneBuilding {
  let inner: FakeCloneBuilder
  let during: @Sendable () -> Void

  func build(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent) async throws -> BuildReport {
    during()
    return try await inner.build(spec: spec, source: source, identity: identity, intent: intent)
  }
}

/// «Изменить…» only renames, swaps or trashes the clone's own app (`ClonePathPolicy`), as checked before the build.
@Suite(.russian) struct EditInstancePolicyTests {
  private func pointWork(_ f: EditFixture, at appPath: String) async throws {
    _ = try await f.store.upsert(Instance(
      slug: testSlug("work"), name: "Claude Work", kind: .clone, bundleId: EditFixture.workId, appPath: appPath,
      profileDir: f.root.appendingPathComponent("profiles/work").path, badge: "W", builtBy: "cmacc"))
  }

  private func attempt(_ engine: EditInstance, name: String, badge: String) async -> EditInstanceError? {
    do {
      _ = try await engine.apply(InstanceChange(slug: testSlug("work"), name: name, badge: badge),
                                 identity: .certificate(sha1: testSHA1, keychain: nil))
      return nil
    } catch {
      return error as? EditInstanceError
    }
  }

  @Test func anEntryPointingAtAnotherAppIsRefusedBeforeTheBuild() async throws {
    let f = try EditFixture()
    let impostor = f.apps.appendingPathComponent("Xcode.app")
    try PolicyFixture.writeApp(impostor, ["CFBundleIdentifier": "com.apple.dt.Xcode"])
    try await pointWork(f, at: impostor.path)
    let error = await attempt(f.engine(), name: "Claude Job", badge: "J")
    guard case .unsafePath(let refusal)? = error else {
      Issue.record("expected unsafePath, got \(String(describing: error))")
      return
    }
    #expect(refusal.code == "foreign-bundle")
    #expect(error?.userMessage == refusal.userMessage)
    #expect(f.log.all.isEmpty && FileManager.default.fileExists(atPath: impostor.appendingPathComponent("Contents/Info.plist").path))
  }

  @Test func anEntryOutsideTheApplicationsFoldersIsRefused() async throws {
    let f = try EditFixture()
    let elsewhere = f.root.appendingPathComponent("Documents/Claude Work.app")
    try EditFixture.makeApp(elsewhere, marker: "old")
    try await pointWork(f, at: elsewhere.path)
    guard case .unsafePath(let refusal)? = await attempt(f.engine(), name: "Claude Job", badge: "J") else {
      Issue.record("expected unsafePath")
      return
    }
    #expect(refusal.code == "app-location" && f.log.all.isEmpty)
  }

  /// The app is replaced while the build runs: the in-place swap refuses and moves nothing.
  @Test func anAppSwappedDuringTheBuildIsNotSwapped() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    let app = f.apps.appendingPathComponent("Claude Work.app")
    let root = f.root
    let builder = InterruptingBuilder(inner: FakeCloneBuilder(paths: f.paths, log: f.log)) {
      try? FileManager.default.moveItem(at: app, to: root.appendingPathComponent("real.app"))
      try? EditFixture.makeApp(app, marker: "impostor")
    }
    let error = await attempt(f.engine(builder: builder), name: "Claude Work", badge: "Wk")
    guard case .unsafePath(let refusal)? = error else {
      Issue.record("expected unsafePath, got \(String(describing: error))")
      return
    }
    #expect(refusal.code == "changed")
    #expect(f.marker("Claude Work.app") == "impostor")
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path)) ?? []).isEmpty)
    #expect(try await f.work() == before && (try f.stagedBuilds()).isEmpty)
    #expect(!f.log.all.contains { $0.hasPrefix("register") })
  }

  /// A letter-case rename sets the old app aside first: an app swapped in meanwhile is not moved.
  @Test func anAppSwappedBeforeALetterCaseRenameIsNotSetAside() async throws {
    let f = try EditFixture()
    let app = f.apps.appendingPathComponent("Claude Work.app")
    let root = f.root
    let builder = InterruptingBuilder(inner: FakeCloneBuilder(paths: f.paths, log: f.log)) {
      try? FileManager.default.moveItem(at: app, to: root.appendingPathComponent("real.app"))
      try? EditFixture.makeApp(app, marker: "impostor")
    }
    guard case .unsafePath(let refusal)? = await attempt(f.engine(builder: builder), name: "Claude WORK", badge: "W") else {
      Issue.record("expected unsafePath")
      return
    }
    #expect(refusal.code == "changed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.apps.path) == ["Claude Work.app"])
    #expect(f.marker("Claude Work.app") == "impostor")
  }

  /// After a rename the old app goes to the Trash only if it is still the one checked; otherwise a warning.
  @Test func anAppSwappedBeforeTheOldCopyIsTrashedStays() async throws {
    let f = try EditFixture()
    let app = f.apps.appendingPathComponent("Claude Work.app")
    let root = f.root
    let builder = InterruptingBuilder(inner: FakeCloneBuilder(paths: f.paths, log: f.log)) {
      try? FileManager.default.moveItem(at: app, to: root.appendingPathComponent("real.app"))
      try? EditFixture.makeApp(app, marker: "impostor")
    }
    let outcome = try await f.engine(builder: builder).apply(
      InstanceChange(slug: testSlug("work"), name: "Claude Job", badge: "J"), identity: .certificate(sha1: testSHA1, keychain: nil))
    #expect(f.marker("Claude Job.app") == "new" && f.marker("Claude Work.app") == "impostor")
    #expect(!f.log.all.contains { $0.hasPrefix("trash") })
    #expect(outcome.warnings.count == 1 && outcome.warnings[0].contains("изменилось"))
    #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
  }
}
