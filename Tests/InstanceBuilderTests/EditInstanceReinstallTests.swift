import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// «Переустановить»: the same clone rebuilt from the current official app in place (same name, label, slug, bundle
/// id and profile), and the backup of every in-place swap forgotten by LaunchServices.
@Suite(.russian) struct EditInstanceReinstallTests {
  private let workId = EditFixture.workId
  private let backupName = "Claude Work.app.20260921-141320"

  @Test func aReinstallWithNothingChangedRebuildsInPlace() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    let outcome = try await f.apply(f.engine(), name: "Claude Work", badge: "W", reinstall: true)
    #expect(f.marker("Claude Work.app") == "new")
    #expect(f.log.all == [
      "build(stagingOnly,certificate,work)", "register(Claude Work.app,new)", "unregister(\(backupName))",
    ])
    let after = try await f.work()
    #expect(outcome.instance == before && after == before)
    #expect(!outcome.renamed && !outcome.wasRunning && !outcome.reopened && outcome.warnings.isEmpty)
    #expect(f.recorder.allStages == [.building, .installing])
    let backup = f.paths.backupDir.appendingPathComponent(backupName)
    #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Contents/Info.plist.disabled").path))
    #expect(try f.stagedBuilds().isEmpty)
  }

  /// The values are trimmed like any change; the flag only lifts the «nothing to change» refusal.
  @Test func aReinstallChangeKeepsItsFlag() {
    let change = InstanceChange(slug: testSlug("work"), name: " Claude Work ", badge: "W ", reinstall: true)
    #expect(change.name == "Claude Work" && change.badge == "W" && change.reinstall)
    #expect(!InstanceChange(slug: testSlug("work"), name: "Claude Work", badge: "W").reinstall)
    #expect(change != InstanceChange(slug: testSlug("work"), name: "Claude Work", badge: "W"))
  }

  /// A running clone is closed only for the swap and opened again, like any in-place edit.
  @Test func aRunningCloneIsClosedForTheReinstallAndOpenedAgain() async throws {
    let f = try EditFixture()
    let apps = EditFakeApps(running: [workId], pollsToQuit: 2, log: f.log)
    let outcome = try await f.apply(f.engine(apps: apps), name: "Claude Work", badge: "W", reinstall: true)
    #expect(f.log.all == [
      "build(stagingOnly,certificate,work)", "quit(\(workId))", "register(Claude Work.app,new)",
      "unregister(\(backupName))", "open(Claude Work.app)",
    ])
    #expect(outcome.wasRunning && outcome.reopened && outcome.warnings.isEmpty)
    #expect(f.recorder.allStages == [.building, .closing, .installing, .reopening])
  }

  /// Without the flag an unchanged clone is still refused; with it the refusals of any edit still apply.
  @Test func refusalsStillApplyToAReinstall() async throws {
    let f = try EditFixture()
    let engine = f.engine()
    let identity = SigningIdentity.certificate(sha1: testSHA1, keychain: nil)
    func attempt(
      _ slug: String, _ name: String, _ badge: String, identity: SigningIdentity = identity
    ) async -> EditInstanceError? {
      do {
        let change = InstanceChange(slug: testSlug(slug), name: name, badge: badge, reinstall: true)
        _ = try await engine.apply(change, identity: identity)
        return nil
      } catch {
        return error as? EditInstanceError
      }
    }
    #expect(await attempt("second", "Claude 2nd", "2nd") == .notEditable(name: "Claude 2nd", reason: .legacy))
    #expect(await attempt("main", "Claude", "M") == .notEditable(name: "Claude", reason: .official))
    #expect(await attempt("work", "Claude Work", "W", identity: .adhoc) == .adhocIdentity)
    #expect(f.log.all.isEmpty && f.marker("Claude Work.app") == "old")
    await #expect(throws: EditInstanceError.nothingToChange) {
      _ = try await f.apply(engine, name: "Claude Work", badge: "W")
    }
  }

  @Test func anUnverifiedReinstallChangesNothing() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    await #expect(throws: EditInstanceError.notVerified(step: "verify")) {
      _ = try await f.apply(f.engine(verified: false), name: "Claude Work", badge: "W", reinstall: true)
    }
    #expect(f.log.all == ["build(stagingOnly,certificate,work)"])
    let after = try await f.work()
    #expect(f.marker("Claude Work.app") == "old" && after == before)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path)) ?? []).isEmpty)
  }

  /// `lsregister -u` of the backup failing is logged only: the edit stands, without a warning.
  @Test func aBackupThatCannotBeUnregisteredDoesNotFailTheEdit() async throws {
    let f = try EditFixture()
    let outcome = try await f.apply(f.engine(unregisterFails: true), name: "Claude Work", badge: "Wk")
    #expect(f.marker("Claude Work.app") == "new" && outcome.instance.badge == "Wk")
    #expect(outcome.warnings.isEmpty)
    #expect(f.log.all.last == "unregister(\(backupName))")
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path) == [backupName])
  }

  /// A rename has no backup: its previous bundle is unregistered and goes to the Trash.
  @Test func aRenameUnregistersTheOldBundleAndKeepsNoBackup() async throws {
    let f = try EditFixture()
    _ = try await f.apply(f.engine(), name: "Claude Job", badge: "J", reinstall: true)
    #expect(f.log.all.filter { $0.hasPrefix("unregister") } == ["unregister(Claude Work.app)"])
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path)) ?? []).isEmpty)
    #expect(f.marker("Claude Job.app") == "new")
  }
}
