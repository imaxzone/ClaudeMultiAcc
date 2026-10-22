import Foundation
import InstanceBuilder
import Support
import Testing
@testable import UI

/// «Обновить N» / «Обновить до …»: one applying pass, then the running clones whose new build the pass left waiting
/// are quit, updated and reopened — after asking, unless «Больше не спрашивать» was chosen.
@MainActor
@Suite(.russian) struct UpdateFlowTests {
  final class Dialogs: UpdateDialogs {
    var answer: UpdateRestartAnswer = .restart(dontAskAgain: false)
    var asked: [[String]] = []
    var reported: [[String]] = []
    func confirmRestart(names: [String]) async -> UpdateRestartAnswer {
      asked.append(names)
      return answer
    }
    func report(problems: [String]) async { reported.append(problems) }
  }

  /// What the fake services saw, in order.
  actor Log {
    var events: [String] = []
    func add(_ event: String) { events.append(event) }
  }

  struct Unreadable: Error {}

  static func clone(_ slug: String, pending: Bool = false) throws -> Instance {
    Instance(
      slug: try Slug(slug), name: "Claude \(slug)", kind: .clone, bundleId: "com.imaxzone.claude.\(slug)",
      appPath: "/Applications/Claude \(slug).app", profileDir: "/p/\(slug)", builtBy: "cmacc",
      pendingBuild: pending ? "/staging/\(slug).app" : nil)
  }

  /// The pass built a new version for a running clone; it waits for the clone to quit.
  static func waits(_ slug: String) -> UpdateDecision {
    UpdateDecision(slug: slug, action: .pending, detail: "running; 3.1 → 3.2 staged")
  }

  struct Harness {
    let flow: UpdateFlow
    let dialogs: Dialogs
    let log: Log
    let settings: SettingsStore
  }

  /// `afterPass` is the registry the pass leaves behind (nil: unreadable); `decisions` what the pass reports.
  static func harness(
    afterPass: [Instance]?, decisions: [UpdateDecision] = [], problems: [String] = [],
    signing: (@Sendable () async throws -> Void)? = nil
  ) throws -> Harness {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("update-flow-\(UUID().uuidString)")
    let settings = SettingsStore(file: dir.appendingPathComponent("settings.json"))
    let log = Log()
    let dialogs = Dialogs()
    let services = UpdateFlowServices(
      ensureSigning: signing ?? { await log.add("sign") },
      applyPending: {
        await log.add("pass")
        return decisions
      },
      loadInstances: {
        guard let afterPass else { throw Unreadable() }
        return afterPass
      },
      restart: { slugs in
        await log.add("restart \(slugs.joined(separator: ","))")
        return CloneRestartReport(updated: slugs, problems: problems)
      })
    let flow = UpdateFlow(services: services, settings: settings, dialogs: dialogs) { await log.add("changed") }
    return Harness(flow: flow, dialogs: dialogs, log: log, settings: settings)
  }

  @Test func aClosedCloneIsUpdatedByThePassAlone() async throws {
    let swap = UpdateDecision(slug: "mv2", action: .swap, detail: "3.1 → 3.2")
    let h = try Self.harness(afterPass: [try Self.clone("mv2")], decisions: [swap])
    await h.flow.run(slugs: ["mv2"])
    #expect(await h.log.events == ["sign", "pass", "changed"])
    #expect(h.dialogs.asked.isEmpty && h.dialogs.reported.isEmpty)
  }

  @Test func aRunningCloneIsQuitUpdatedAndReopenedAfterAsking() async throws {
    let decisions = [Self.waits("2nd"), UpdateDecision(slug: "mv2", action: .pendingWaiting, detail: "running")]
    let h = try Self.harness(
      afterPass: [try Self.clone("2nd", pending: true), try Self.clone("mv2", pending: true)], decisions: decisions)
    await h.flow.run(slugs: ["2nd", "mv2"])
    #expect(h.dialogs.asked == [["Claude 2nd", "Claude mv2"]])
    #expect(await h.log.events == ["sign", "pass", "changed", "restart 2nd,mv2", "changed"])
    #expect(h.dialogs.reported.isEmpty)
  }

  @Test func onlyTheChosenClonesAreRestarted() async throws {
    let h = try Self.harness(
      afterPass: [try Self.clone("2nd", pending: true), try Self.clone("mv2", pending: true)],
      decisions: [Self.waits("2nd"), Self.waits("mv2")])
    await h.flow.run(slugs: ["mv2"])
    #expect(h.dialogs.asked == [["Claude mv2"]])
    #expect(await h.log.events.contains("restart mv2"))
  }

  /// A leftover `pendingBuild` whose new pass failed would only reopen the old version: nobody is quit for it.
  @Test(arguments: [
    UpdateDecision(slug: "2nd", action: .fail, detail: "codesign failed"),
    UpdateDecision(slug: "2nd", action: .needsIdentity, detail: "no identity"),
    UpdateDecision(slug: "2nd", action: .retry, detail: "vendor ShipIt installing"),
  ])
  func aCloneTheNewPassCouldNotBuildIsNotQuit(decision: UpdateDecision) async throws {
    let h = try Self.harness(afterPass: [try Self.clone("2nd", pending: true)], decisions: [decision])
    await h.flow.run(slugs: ["2nd"])
    #expect(h.dialogs.asked.isEmpty)
    #expect(await !h.log.events.contains { $0.hasPrefix("restart") })
    #expect(h.dialogs.reported.count == 1)
  }

  @Test func cancellingLeavesTheBuildWaiting() async throws {
    let h = try Self.harness(afterPass: [try Self.clone("2nd", pending: true)], decisions: [Self.waits("2nd")])
    h.dialogs.answer = .cancel
    await h.flow.run(slugs: ["2nd"])
    #expect(await h.log.events == ["sign", "pass", "changed"])
    #expect(h.dialogs.reported.isEmpty)
  }

  @Test func dontAskAgainIsRememberedAndHonoured() async throws {
    let h = try Self.harness(afterPass: [try Self.clone("2nd", pending: true)], decisions: [Self.waits("2nd")])
    h.dialogs.answer = .restart(dontAskAgain: true)
    await h.flow.run(slugs: ["2nd"])
    #expect(await h.settings.load().updates.askBeforeRestart == false)
    await h.flow.run(slugs: ["2nd"])
    #expect(h.dialogs.asked.count == 1)
    #expect(await h.log.events.filter { $0.hasPrefix("restart") }.count == 2)
  }

  @Test func passFailuresAndRestartProblemsAreReportedTogether() async throws {
    let decisions = [
      UpdateDecision(slug: "mv2", action: .fail, detail: "codesign failed\nmore output"),
      UpdateDecision(slug: "work", action: .fail, detail: "not chosen"),
      Self.waits("2nd"),
    ]
    let h = try Self.harness(
      afterPass: [try Self.clone("2nd", pending: true), try Self.clone("mv2"), try Self.clone("work")],
      decisions: decisions, problems: ["«Claude 2nd» не закрылся — новая версия встанет после его закрытия"])
    await h.flow.run(slugs: ["2nd", "mv2"])
    #expect(h.dialogs.reported == [[
      "«Claude mv2»: не удалось собрать новую версию — codesign failed",
      "«Claude 2nd» не закрылся — новая версия встанет после его закрытия",
    ]])
  }

  /// The pass did not run for anyone: another update, an edit or a delete holds `update.lock`.
  @Test(arguments: [UpdateDecision.Action.skippedLocked, .coalesced])
  func aBusyPassIsExplained(action: UpdateDecision.Action) async throws {
    let decisions = [UpdateDecision(slug: "all", action: action, detail: "another pass holds update.lock")]
    let h = try Self.harness(afterPass: [try Self.clone("mv2")], decisions: decisions)
    await h.flow.run(slugs: ["mv2"])
    #expect(h.dialogs.reported == [[UpdateFlowText.busy]])
  }

  @Test func aPassThatCouldNotStartIsExplained() async throws {
    let decisions = [UpdateDecision(slug: "all", action: .fail, detail: "cannot lock update.lock (errno 13)")]
    let h = try Self.harness(afterPass: [try Self.clone("mv2")], decisions: decisions)
    await h.flow.run(slugs: ["mv2"])
    #expect(h.dialogs.reported == [["Не удалось начать обновление — cannot lock update.lock (errno 13)"]])
  }

  @Test func anUnreadableRegistryIsReportedAndNothingIsQuit() async throws {
    let h = try Self.harness(afterPass: nil, decisions: [Self.waits("2nd")])
    await h.flow.run(slugs: ["2nd"])
    #expect(h.dialogs.asked.isEmpty)
    #expect(h.dialogs.reported == [[UpdateFlowText.registryUnreadable]])
  }

  /// With `updates.autoRebuild` off the pass builds nothing: the line says why.
  @Test func autoRebuildOffIsExplained() async throws {
    let decisions = [UpdateDecision(slug: "mv2", action: .skip, detail: UpdateDecision.autoRebuildOff)]
    let h = try Self.harness(afterPass: [try Self.clone("mv2")], decisions: decisions)
    await h.flow.run(slugs: ["mv2"])
    #expect(h.dialogs.reported == [[
      "«Claude mv2»: автосборка новых версий выключена (updates.autoRebuild в settings.json)",
    ]])
  }

  @Test func aSigningFailureStopsBeforeThePassWithAReadableReason() async throws {
    let h = try Self.harness(afterPass: [try Self.clone("mv2")], signing: { throw SigningKeychainError.lockUnavailable })
    await h.flow.run(slugs: ["mv2"])
    #expect(await h.log.events.isEmpty)
    #expect(h.dialogs.reported == [[
      "Не удалось подготовить подпись для сборки: \(UserMessage.text(for: SigningKeychainError.lockUnavailable))",
    ]])
  }

  @Test func aSecondRequestWhileRunningIsIgnored() async throws {
    let h = try Self.harness(afterPass: [try Self.clone("mv2")])
    h.flow.update(slugs: ["mv2"])
    h.flow.update(slugs: ["mv2"])
    await h.flow.work?.value
    #expect(await h.log.events.filter { $0 == "pass" }.count == 1)
    #expect(!h.flow.isRunning)
  }

  /// The menu shows «Обновляется…» from the click until the run ends.
  @Test func theMenuHearsWhenARunStartsAndEnds() async throws {
    let h = try Self.harness(afterPass: [try Self.clone("mv2")])
    var seen: [Bool] = []
    h.flow.onRunningChange = { [flow = h.flow] in seen.append(flow.isRunning) }
    h.flow.update(slugs: ["mv2"])
    await h.flow.work?.value
    #expect(seen == [true, false])
  }

  @Test func nothingChosenDoesNothing() async throws {
    let h = try Self.harness(afterPass: [])
    h.flow.update(slugs: [])
    #expect(h.flow.work == nil)
  }
}
