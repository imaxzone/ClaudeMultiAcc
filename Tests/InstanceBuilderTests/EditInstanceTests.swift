import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// «Изменить…»: rebuild with a new name and label, swap or rename, keep slug, bundle id and profile.
@Suite(.russian) struct EditInstanceTests {
  private let workId = EditFixture.workId

  @Test func aNewLabelIsSwappedInPlaceAndOnlyTheLabelChanges() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    let outcome = try await f.apply(f.engine(), name: "Claude Work", badge: "Wk")
    #expect(f.marker("Claude Work.app") == "new")
    // The backup keeps the clone's bundle id: LaunchServices forgets it, so macOS never opens the old copy.
    #expect(f.log.all == [
      "build(stagingOnly,certificate,work)", "register(Claude Work.app,new)", "unregister(Claude Work.app.20260921-141320)",
    ])
    let after = try await f.work()
    #expect(after == outcome.instance && after.badge == "Wk" && after.name == "Claude Work")
    #expect(after.slug == before.slug && after.bundleId == before.bundleId && after.profileDir == before.profileDir)
    #expect(after.appPath == before.appPath && after.emails == before.emails && after.accountUuid == before.accountUuid)
    #expect(!outcome.renamed && !outcome.wasRunning && !outcome.reopened && outcome.warnings.isEmpty)
    let backups = try FileManager.default.contentsOfDirectory(atPath: f.paths.backupDir.path)
    #expect(backups == ["Claude Work.app.20260921-141320"])
    #expect(try f.stagedBuilds().isEmpty)
    #expect(f.recorder.allStages == [.building, .installing])
  }

  @Test func aNewNameMovesTheAppAndTrashesTheOldOneAfterInstalling() async throws {
    let f = try EditFixture()
    let outcome = try await f.apply(f.engine(), name: "Claude Job", badge: "J")
    #expect(f.marker("Claude Job.app") == "new")
    #expect(!FileManager.default.fileExists(atPath: f.apps.appendingPathComponent("Claude Work.app").path))
    #expect(f.log.all == [
      "build(stagingOnly,certificate,work)", "register(Claude Job.app,new)", "unregister(Claude Work.app)",
      "trash(Claude Work.app)",
    ])
    let trashed = f.trashBin.appendingPathComponent("Claude Work.app/Contents")
    #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("Info.plist.disabled").path))
    let work = try await f.work()
    #expect(work == outcome.instance && outcome.renamed)
    #expect(work.name == "Claude Job" && work.badge == "J" && work.slug.raw == "work" && work.bundleId == workId)
    #expect(work.appPath == f.apps.appendingPathComponent("Claude Job.app").path)
    #expect(work.profileDir == f.root.appendingPathComponent("profiles/work").path)
    #expect(work.builtBy == "cmacc" && work.pendingBuild == nil)
    #expect(try f.stagedBuilds().isEmpty)
  }

  /// The build runs while the clone is open; it is closed only for the swap and opened again (the new app).
  @Test func aRunningCloneIsClosedForTheSwapAndOpenedAgain() async throws {
    let f = try EditFixture()
    let apps = EditFakeApps(running: [workId], pollsToQuit: 3, log: f.log)
    let outcome = try await f.apply(f.engine(apps: apps), name: "Claude Job", badge: "J")
    #expect(f.log.all == [
      "build(stagingOnly,certificate,work)", "quit(\(workId))", "register(Claude Job.app,new)",
      "unregister(Claude Work.app)", "trash(Claude Work.app)", "open(Claude Job.app)",
    ])
    #expect(outcome.wasRunning && outcome.reopened && outcome.warnings.isEmpty)
    #expect(f.recorder.allStages == [.building, .closing, .installing, .reopening])
    #expect(f.recorder.slept > .zero && f.recorder.slept <= EditInstance.quitTimeout)
  }

  @Test func aCloneThatDoesNotQuitKeepsRunningUnchanged() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    let apps = EditFakeApps(running: [workId], stuck: true, log: f.log)
    await #expect(throws: EditInstanceError.stillRunning("Claude Work")) {
      _ = try await f.apply(f.engine(apps: apps), name: "Claude Job", badge: "J")
    }
    #expect(f.marker("Claude Work.app") == "old")
    #expect(try await f.work() == before)
    #expect(try f.stagedBuilds().isEmpty)
    #expect(!f.log.all.contains { $0.hasPrefix("register") || $0.hasPrefix("open") })
    #expect(f.recorder.slept == EditInstance.quitTimeout)
  }

  @Test func anUnverifiedBuildChangesNothing() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    let apps = EditFakeApps(running: [workId], log: f.log)
    await #expect(throws: EditInstanceError.notVerified(step: "verify")) {
      _ = try await f.apply(f.engine(apps: apps, verified: false), name: "Claude Job", badge: "J")
    }
    #expect(f.log.all == ["build(stagingOnly,certificate,work)"])
    #expect(f.marker("Claude Work.app") == "old")
    #expect(try await f.work() == before)
    #expect(try f.stagedBuilds().isEmpty)
  }

  @Test func refusalsHappenBeforeAnythingIsBuilt() async throws {
    let f = try EditFixture()
    try EditFixture.makeApp(f.apps.appendingPathComponent("Claude Taken.app"), marker: "x")
    let engine = f.engine()
    let identity = SigningIdentity.certificate(sha1: testSHA1, keychain: nil)
    func attempt(_ slug: String, _ name: String, _ badge: String, identity: SigningIdentity = identity) async -> EditInstanceError? {
      do {
        _ = try await engine.apply(InstanceChange(slug: testSlug(slug), name: name, badge: badge), identity: identity)
        return nil
      } catch {
        return error as? EditInstanceError
      }
    }
    #expect(await attempt("nope", "X", "X") == .notFound("nope"))
    #expect(await attempt("main", "Claude X", "X") == .notEditable(name: "Claude", reason: .official))
    #expect(await attempt("alt", "Claude X", "X") == .notEditable(name: "Claude (alt CLI)", reason: .noApp))
    #expect(await attempt("second", "Claude X", "X") == .notEditable(name: "Claude 2nd", reason: .legacy))
    #expect(await attempt("work", "Claude 2nd", "W") == .invalid([.nameTaken("Claude 2nd")]))
    #expect(await attempt("work", "Claude Work", "Работа") == .invalid([.badgeTooLong(6)]))
    #expect(await attempt("work", " Claude Work ", "W ") == .nothingToChange)
    #expect(await attempt("work", "Claude Taken", "W") == .targetExists(f.apps.appendingPathComponent("Claude Taken.app").path))
    #expect(await attempt("work", "Claude Job", "J", identity: .adhoc) == .adhocIdentity)
    #expect(f.log.all.isEmpty)
  }

  /// Registration of the renamed app fails: it goes back to staging, the old app stays and is opened again.
  @Test func aFailedRegistrationPutsTheOldAppBack() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    let apps = EditFakeApps(running: [workId], log: f.log)
    let registrar = EditFailingRegistrar(log: f.log, failing: ["Claude Job.app"])
    await #expect(throws: EditInstanceError.self) {
      _ = try await f.apply(f.engine(apps: apps, registrar: registrar), name: "Claude Job", badge: "J")
    }
    #expect(f.marker("Claude Work.app") == "old")
    #expect(!FileManager.default.fileExists(atPath: f.apps.appendingPathComponent("Claude Job.app").path))
    #expect(try await f.work() == before)
    #expect(f.log.all.suffix(2) == ["register(Claude Work.app,failing=false)", "open(Claude Work.app)"])
    #expect(!f.log.all.contains { $0.hasPrefix("trash") })
    #expect(try f.stagedBuilds().isEmpty)
  }

  @Test func aFailedStoreWriteAfterAnInPlaceSwapRestoresTheOldApp() async throws {
    let f = try EditFixture()
    let before = try await f.work()
    do {
      _ = try await f.apply(f.engine(storeFails: true), name: "Claude Work", badge: "Wk")
      Issue.record("expected a failure")
    } catch let error as EditInstanceError {
      guard case .installFailed(let step, _) = error else { Issue.record("got \(error)"); return }
      #expect(step == "store")
      #expect(!error.userMessage.isEmpty)
    }
    #expect(f.marker("Claude Work.app") == "old")
    #expect(try await f.work() == before)
    #expect(FileManager.default.fileExists(atPath: f.apps.appendingPathComponent("Claude Work.app/Contents/Info.plist").path))
    #expect(!f.log.all.contains { $0.hasPrefix("unregister") })
  }

  /// A letter-case-only rename on a case-insensitive volume: the old bundle is set aside under a hidden name first.
  @Test func aLetterCaseRenameSetsTheOldAppAside() async throws {
    let f = try EditFixture()
    let outcome = try await f.apply(f.engine(), name: "Claude WORK", badge: "W")
    let names = try FileManager.default.contentsOfDirectory(atPath: f.apps.path)
    #expect(names == ["Claude WORK.app"])
    #expect(f.marker("Claude WORK.app") == "new" && outcome.renamed)
    #expect(f.log.all.count == 3 && f.log.all.prefix(2) == ["build(stagingOnly,certificate,work)", "register(Claude WORK.app,new)"])
    #expect(f.log.all.last?.hasPrefix("trash(.Claude Work.app.replaced") == true)
    #expect(try await f.work().appPath == f.apps.appendingPathComponent("Claude WORK.app").path)
  }

  @Test func aBusyUpdatePassMeansTryAgainLater() async throws {
    let f = try EditFixture()
    guard case .acquired(let held) = UpdateLock.acquire(UpdateLock.file(f.paths)) else {
      Issue.record("could not take the lock")
      return
    }
    defer { held.release() }
    await #expect(throws: EditInstanceError.busy) {
      _ = try await f.apply(f.engine(), name: "Claude Job", badge: "J")
    }
    #expect(f.marker("Claude Work.app") == "old")
    #expect(try f.stagedBuilds().isEmpty)
  }

  @Test func reopenAndTrashFailuresAreWarningsNotFailures() async throws {
    let f = try EditFixture()
    let apps = EditFakeApps(running: [workId], log: f.log)
    let outcome = try await f.apply(f.engine(apps: apps, trashFails: true, openFails: true), name: "Claude Job", badge: "J")
    #expect(f.marker("Claude Job.app") == "new" && outcome.instance.name == "Claude Job")
    #expect(outcome.wasRunning && !outcome.reopened)
    #expect(outcome.warnings.count == 2)
    #expect(outcome.warnings.allSatisfy { $0.range(of: "[А-Яа-я]", options: .regularExpression) != nil })
  }

  /// A waiting update build of the clone is superseded: the edit builds from the current official app.
  @Test func aWaitingUpdateBuildIsDroppedAndCleared() async throws {
    let f = try EditFixture()
    let dir = try StagingArea(paths: f.paths, timeZone: .gmt)
      .newBuildDir(slug: testSlug("work"), now: Date(timeIntervalSince1970: 1_700_000_000))
    let pending = dir.appendingPathComponent("Claude Work.app", isDirectory: true)
    try EditFixture.makeApp(pending, marker: "pending")
    _ = try await f.store.upsert(try await f.work().withBuild(builtBy: "cmacc", pendingBuild: pending.path))
    let outcome = try await f.apply(f.engine(), name: "Claude Work", badge: "Wk")
    #expect(outcome.instance.pendingBuild == nil)
    #expect(try await f.work().pendingBuild == nil)
    #expect(try f.stagedBuilds().isEmpty)
  }

  @Test func theRenameTargetSitsNextToTheAppAndIgnoresLetterCase() throws {
    let instance = Instance(slug: testSlug("work"), name: "Claude Work", kind: .clone, appPath: "/Applications/Claude Work.app")
    #expect(EditInstance.renameTarget(of: instance, to: "Claude Work") == nil)
    #expect(EditInstance.renameTarget(of: instance, to: " claude work ") == nil)
    #expect(EditInstance.renameTarget(of: instance, to: "Claude Job")?.path == "/Applications/Claude Job.app")
  }

  @Test func errorsHaveRussianMessagesWithoutTechnicalDetails() {
    let errors: [EditInstanceError] = [
      .storeUnreadable("x"), .notFound("x"), .notEditable(name: "Claude", reason: .official),
      .notEditable(name: "A", reason: .noApp), .notEditable(name: "A", reason: .legacy),
      .notEditable(name: "A", reason: .incomplete), .invalid([.emptyName]), .nothingToChange, .targetExists("/A/B.app"),
      .adhocIdentity, .notVerified(step: "sign"), .notVerified(step: nil), .busy, .stillRunning("Claude Work"),
      .installFailed(step: "register", message: "boom"), .compensationFailed(step: "store", leftAt: "/A/B.app"),
      .unsafePath(.changed(name: "A", path: "/A/B.app")), .unsafePath(.bundleId(name: "A", bundleId: "com.boom")),
    ]
    for error in errors {
      #expect(error.userMessage.range(of: "[А-Яа-я]", options: .regularExpression) != nil, "\(error)")
      #expect(!error.userMessage.contains("boom"))
      #expect(error.description.range(of: "[А-Яа-я]", options: .regularExpression) == nil, "\(error)")
    }
  }
}
