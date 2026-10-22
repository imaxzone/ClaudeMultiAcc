import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// `remove(slug:mode:)` on the fixture of `InstanceRemoverTests.swift`: what moves, in which order, and what stops it.
@Suite(.russian) struct InstanceRemoverFlowTests {
  private let allSlugs = ["main", "second", "mv2", "work", "alt"]

  @Test func appOnlyTrashesTheAppAndItsOldCopiesAndKeepsTheProfile() async throws {
    let f = try await RemovalFixture()
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(f.events.all == [
      "lock", "trash(\(RemovalFixture.mv2App))", "unregister(\(RemovalFixture.mv2App))", "unregister(Trash/Claude mv2.app)",
      "trash(\(RemovalFixture.backups[0]))", "trash(\(RemovalFixture.backups[1]))", "trash(\(RemovalFixture.staging))",
      "unlock",
    ])
    #expect(report.problems.isEmpty && report.recordRemoved && report.notTrashed.isEmpty)
    #expect(report.trashed.map { RemovalFixture.relative($0, root: f.root) }
      == [RemovalFixture.mv2App] + RemovalFixture.backups + [RemovalFixture.staging])
    #expect(f.exists(RemovalFixture.mv2Profile))
    #expect(try await f.slugs() == ["main", "second", "work", "alt"])
    for decoy in ["data/backup/Claude mv2 work.app.20261001-120000", "data/backup/Claude Work.app.20261001-120000",
                  "data/backup/Claude mv2.app.bak", "data/staging/mv2x-20261020-101010.noindex",
                  "data/staging/work-20261020-101010.noindex", "data/backup/Claude mv2.app.20261002-120000",
                  "outside/big", "Applications/Claude.app"] {
      #expect(f.exists(decoy), "\(decoy) must stay")
    }
    let log = try f.log()
    #expect(log.contains("[instances] remove mv2: start (appOnly)"))
    #expect(log.contains("[instances] remove mv2: removed from instances.json"))
  }

  @Test func everythingAlsoTrashesTheProfileLast() async throws {
    let f = try await RemovalFixture()
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(f.events.all.filter { $0.hasPrefix("trash(") } == [
      "trash(\(RemovalFixture.mv2App))", "trash(\(RemovalFixture.backups[0]))", "trash(\(RemovalFixture.backups[1]))",
      "trash(\(RemovalFixture.staging))", "trash(\(RemovalFixture.mv2Profile))",
    ])
    #expect(report.problems.isEmpty && report.recordRemoved)
    #expect(!f.exists(RemovalFixture.mv2Profile) && f.exists("Library/Application Support/Claude/config.json"))
    #expect(try await f.slugs() == ["main", "second", "work", "alt"])
  }

  @Test func quitsARunningAppPolitelyBeforeTrashing() async throws {
    let f = try await RemovalFixture(.init(running: true))
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(Array(f.events.all.prefix(3)) == ["lock", "quit(\(RemovalFixture.mv2Id))", "trash(\(RemovalFixture.mv2App))"])
    #expect(report.problems.isEmpty && report.recordRemoved)
    #expect(f.sleeps.total == .milliseconds(500))
  }

  @Test func abortsAndChangesNothingWhenTheAppDoesNotQuit() async throws {
    let f = try await RemovalFixture(.init(running: true, stuck: true))
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(f.events.all == ["lock", "quit(\(RemovalFixture.mv2Id))", "unlock"])
    #expect(report.problems == ["«Claude mv2» не закрылся за 30 секунд. Закройте его и попробуйте снова — ничего не удалено."])
    #expect(report.changedNothing && f.exists(RemovalFixture.mv2App) && f.exists(RemovalFixture.mv2Profile))
    #expect(try await f.slugs() == allSlugs)
    #expect(f.sleeps.total == .seconds(30))
    #expect(try f.log().contains("did not quit in 30 s"))
  }

  @Test func abortsWhenAnUpdateHoldsTheLock() async throws {
    let f = try await RemovalFixture(.init(lockBusyAttempts: .max))
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(report.problems == ["Сейчас обновляются приложения. Попробуйте удалить «Claude mv2» через пару минут — ничего не удалено."])
    #expect(report.changedNothing && !f.events.all.contains { $0.hasPrefix("trash(") })
    #expect(f.sleeps.total == .seconds(30))
    #expect(try await f.slugs() == allSlugs)
  }

  @Test func aBackupMadeWhileWaitingForTheLockGoesToo() async throws {
    let late = "data/backup/Claude mv2.app.20261021-090000"
    var knobs = RemovalFixture.Knobs(lockBusyAttempts: 2)
    knobs.whileLockBusy = { root in
      try? FileManager.default.createDirectory(at: root.appendingPathComponent(late), withIntermediateDirectories: true)
    }
    let f = try await RemovalFixture(knobs)
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(Array(f.events.all.prefix(3)) == ["lock-busy", "lock-busy", "lock"])
    #expect(report.trashed.map { RemovalFixture.relative($0, root: f.root) }
      == [RemovalFixture.mv2App, RemovalFixture.backups[0], late, RemovalFixture.backups[1], RemovalFixture.staging])
    #expect(report.problems.isEmpty && f.sleeps.total == .seconds(1))
  }

  @Test func aFailedAppTrashStopsEverythingAndKeepsTheRecord() async throws {
    let f = try await RemovalFixture(.init(trashFailing: [RemovalFixture.mv2App]))
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(f.events.all == ["lock", "trash(\(RemovalFixture.mv2App))", "unlock"])
    #expect(report.changedNothing && report.notTrashed.count == 1)
    #expect(report.problems.count == 1)
    #expect(report.problems[0].hasPrefix("Не удалось переместить «Claude mv2» в Корзину:"))
    #expect(report.problems[0].hasSuffix("Ничего не удалено."))
    #expect(f.exists(RemovalFixture.mv2App) && f.exists(RemovalFixture.backups[0]) && f.exists(RemovalFixture.mv2Profile))
    #expect(try await f.slugs() == allSlugs)
  }

  @Test func aLaterFailureIsReportedWithWhatWasAndWasNotMoved() async throws {
    let f = try await RemovalFixture(.init(trashFailing: [RemovalFixture.mv2Profile, RemovalFixture.backups[1]]))
    let report = await f.remover.remove(slug: "mv2", mode: .everything)
    #expect(report.recordRemoved && !report.changedNothing)
    #expect(report.trashed.map { RemovalFixture.relative($0, root: f.root) }
      == [RemovalFixture.mv2App, RemovalFixture.backups[0], RemovalFixture.staging])
    #expect(report.notTrashed.map { RemovalFixture.relative($0, root: f.root) }
      == [RemovalFixture.backups[1], RemovalFixture.mv2Profile])
    #expect(report.problems.count == 3)
    #expect(report.problems[0] == "В Корзину перемещено: приложение «Claude mv2», старая копия "
      + "(~/data/backup/Claude mv2.app.20261001-120000), сборка обновления (~/\(RemovalFixture.staging)).")
    #expect(report.problems[1].hasPrefix("Не перемещено: старая копия (~/\(RemovalFixture.backups[1])) — "))
    #expect(report.problems[2].hasPrefix("Не перемещено: вход, настройки и кэш (~/\(RemovalFixture.mv2Profile)) — "))
    #expect(try await f.slugs() == ["main", "second", "work", "alt"])
  }

  @Test func anAppAlreadyGoneStillLeavesTheList() async throws {
    let f = try await RemovalFixture()
    try FileManager.default.removeItem(at: f.root.appendingPathComponent(RemovalFixture.mv2App))
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(!f.events.contains("trash(\(RemovalFixture.mv2App))") && !f.events.all.contains { $0.hasPrefix("unregister") })
    #expect(report.problems.isEmpty && report.recordRemoved)
    #expect(try await f.slugs() == ["main", "second", "work", "alt"])
  }

  @Test func aFailedUnregisterIsOnlyLogged() async throws {
    let f = try await RemovalFixture(.init(unregisterFails: true))
    let report = await f.remover.remove(slug: "mv2", mode: .appOnly)
    #expect(report.problems.isEmpty && report.recordRemoved)
    #expect(try f.log().contains("lsregister -u"))
  }
}
