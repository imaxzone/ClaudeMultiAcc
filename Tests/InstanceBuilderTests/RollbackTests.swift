import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Rollback puts `builtBy` back for a legacy backup (S1) and never fails its undo silently (S5).
extension RebuildSecondTests {
  private func secondInstance(_ paths: Paths) async throws -> Instance {
    try #require(try await InstanceStore(paths: paths).load().first { $0.slug.raw == "second" })
  }

  @Test func rollbackOfALegacyBackupMarksSecondLegacyAgain() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let rebuild = RebuildSecond(env: f.env)
    let result = try await rebuild.apply()
    #expect(result.backup.lastPathComponent.hasPrefix("legacy-"))
    #expect(try await secondInstance(f.paths).builtBy == "cmacc")
    let store = InstanceStore(paths: f.paths)
    let pending = try await secondInstance(f.paths).withBuild(builtBy: "cmacc", pendingBuild: "/staging/x")
    _ = try await store.upsert(pending)
    try await rebuild.rollback(backup: result.backup)
    let second = try await secondInstance(f.paths)
    #expect(second.builtBy == "legacy-script")
    #expect(second.pendingBuild == nil)
    // A second apply then protects the restored legacy build again.
    #expect(await rebuild.backupPrefix() == "legacy-")
  }

  @Test func rollbackOfAPlainBackupKeepsBuiltBy() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let store = InstanceStore(paths: f.paths)
    let seeded = try await store.load().map { $0.slug.raw == "second" ? $0.withBuild(builtBy: "cmacc", pendingBuild: nil) : $0 }
    try await store.save(seeded)
    let rebuild = RebuildSecond(env: f.env)
    let result = try await rebuild.apply()
    #expect(!result.backup.lastPathComponent.hasPrefix("legacy-"))
    try await rebuild.rollback(backup: result.backup)
    #expect(try await secondInstance(f.paths).builtBy == "cmacc")
  }

  /// Rollback renames: 1 live→failed-dir, 2 disable its plist, 3 enable backup plist, 4 backup→live (fails),
  /// 5 disable backup plist again, 6 enable aside plist, 7 aside→live (fails).
  @Test func rollbackDisablesTheBackupAgainAndNamesWhereTheLiveAppWasLeft() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let result = try await RebuildSecond(env: f.env).apply()
    let scripted = ScriptedMover(failing: [4, 7])
    let rebuild = RebuildSecond(env: f.env.with(mover: scripted.mover))
    let aside = f.paths.backupDir.appendingPathComponent("failed-20260921-141320/Claude 2nd.app")
    do {
      try await rebuild.rollback(backup: result.backup)
      Issue.record("rollback must throw")
    } catch let RebuildError.compensationFailed(_, leftAt) {
      #expect(leftAt == aside.path)
    }
    #expect(scripted.attempts.count == 7)
    // The backup is disabled again, so LaunchServices keeps ignoring it and a later rollback still accepts it.
    #expect(FileManager.default.fileExists(atPath: result.backup.appendingPathComponent("Contents/Info.plist.disabled").path))
    #expect(RebuildError.compensationFailed(original: "x", leftAt: "/b/app").description.contains("/b/app"))
  }
}

/// `check` and `apply` share `<data>/update.lock` with the UpdateWatcher (S3).
extension RebuildSecondTests {
  @Test func checkAndApplyRefuseWhileAnotherPassHoldsTheUpdateLock() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    guard case .acquired(let held) = UpdateLock.acquire(UpdateLock.file(f.paths)) else {
      Issue.record("cannot take the lock")
      return
    }
    let rebuild = RebuildSecond(env: f.env)
    let items = await rebuild.check(keepStaging: false)
    #expect(items.map(\.line) == ["FAIL update-lock — another pass holds update.lock — retry in a minute"])
    await #expect(throws: RebuildError.preflightFailed([PreflightItem.updateLock])) {
      _ = try await rebuild.apply()
    }
    #expect(f.log.all.isEmpty)
    held.release()
    let free = await rebuild.check(keepStaging: false)
    #expect(free.first?.line == "PASS update-lock — free")
    #expect(free.filter { !$0.passed }.isEmpty)
  }
}
