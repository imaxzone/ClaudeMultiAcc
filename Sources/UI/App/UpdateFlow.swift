import Foundation
import InstanceBuilder
import os
import Support

/// The answer to «Перезапустить … и обновить?».
public enum UpdateRestartAnswer: Equatable, Sendable {
  case cancel
  case restart(dontAskAgain: Bool)
}

/// The confirmation before running clones are quit, and the one report of what went wrong.
@MainActor
public protocol UpdateDialogs: AnyObject {
  /// `names` are the running clones that will quit, in list order.
  func confirmRestart(names: [String]) async -> UpdateRestartAnswer
  /// One line per problem; never called with an empty list.
  func report(problems: [String]) async
}

/// What the flow drives: the permanent signing identity, one applying pass of the update watcher, a fresh read of
/// `instances.json` and the restart of clones whose build waits for them.
public struct UpdateFlowServices: Sendable {
  public var ensureSigning: @Sendable () async throws -> Void
  public var applyPending: @Sendable () async -> [UpdateDecision]
  public var loadInstances: @Sendable () async throws -> [Instance]
  public var restart: @Sendable ([String]) async -> CloneRestartReport

  public init(
    ensureSigning: @escaping @Sendable () async throws -> Void,
    applyPending: @escaping @Sendable () async -> [UpdateDecision],
    loadInstances: @escaping @Sendable () async throws -> [Instance],
    restart: @escaping @Sendable ([String]) async -> CloneRestartReport
  ) {
    self.ensureSigning = ensureSigning
    self.applyPending = applyPending
    self.loadInstances = loadInstances
    self.restart = restart
  }
}

/// «Обновить N» / «Обновить до …». One applying pass builds every clone that is behind; a closed clone gets its new
/// version right there. The chosen clones that are running keep a verified build in `pendingBuild`: after asking
/// (unless «Больше не спрашивать» was chosen) they are quit, updated and reopened. Everything that went wrong is
/// shown in one alert. One run at a time; a request during a run is ignored.
@MainActor
public final class UpdateFlow {
  public private(set) var isRunning = false {
    didSet { if isRunning != oldValue { onRunningChange?() } }
  }
  /// Runs when a run starts and when it ends (the menu shows «Обновляется…» meanwhile).
  public var onRunningChange: (() -> Void)?
  /// The run started by the latest `update(slugs:)` (awaited by tests).
  public private(set) var work: Task<Void, Never>?

  private let services: UpdateFlowServices
  private let settings: SettingsStore
  private let dialogs: any UpdateDialogs
  private let didChange: @MainActor () async -> Void
  private let log = AppLog.logger("update-flow")

  /// `didChange` runs after the pass and after a restart (reload the instance list and the menu).
  public init(
    services: UpdateFlowServices, settings: SettingsStore, dialogs: any UpdateDialogs,
    didChange: @escaping @MainActor () async -> Void
  ) {
    self.services = services
    self.settings = settings
    self.dialogs = dialogs
    self.didChange = didChange
  }

  public func update(slugs: [String]) {
    guard !slugs.isEmpty, !isRunning else { return }
    isRunning = true
    work = Task {
      await run(slugs: slugs)
      isRunning = false
    }
  }

  func run(slugs: [String]) async {
    do {
      try await services.ensureSigning()
    } catch {
      log.error("Signing is not ready: \(String(describing: error), privacy: .public)")
      await dialogs.report(problems: [UpdateFlowText.signingFailed(UserMessage.text(for: error))])
      return
    }
    let decisions = await services.applyPending()
    await didChange()
    let instances: [Instance]
    do {
      instances = try await services.loadInstances()
    } catch {
      log.error("Cannot read instances.json after the pass: \(String(describing: error), privacy: .public)")
      await dialogs.report(problems: [UpdateFlowText.registryUnreadable])
      return
    }
    var problems = Self.passProblems(decisions, chosen: slugs, instances: instances)
    let waiting = Self.waitingForQuit(decisions, chosen: slugs, instances: instances)
    if !waiting.isEmpty, await confirm(waiting.map(\.name)) {
      let report = await services.restart(waiting.map(\.slug.raw))
      problems += report.problems
      await didChange()
    }
    if !problems.isEmpty { await dialogs.report(problems: problems) }
  }

  /// The chosen clones this pass left a verified new build for, waiting for them to quit. A leftover
  /// `pendingBuild` whose pass failed is not one of them: quitting the clone would only reopen the old version.
  static func waitingForQuit(_ decisions: [UpdateDecision], chosen: [String], instances: [Instance]) -> [Instance] {
    let waiting = Set(decisions.filter { [.pending, .pendingWaiting].contains($0.action) }.map(\.slug))
    return instances.filter {
      chosen.contains($0.slug.raw) && waiting.contains($0.slug.raw) && $0.kind == .clone && $0.pendingBuild != nil
    }
  }

  /// Asks unless the owner chose «Больше не спрашивать»; remembers that choice.
  private func confirm(_ names: [String]) async -> Bool {
    guard await settings.load().updates.askBeforeRestart else { return true }
    switch await dialogs.confirmRestart(names: names) {
    case .cancel:
      return false
    case .restart(let dontAskAgain):
      if dontAskAgain { await remember() }
      return true
    }
  }

  private func remember() async {
    do {
      _ = try await settings.update { settings in
        var settings = settings
        settings.updates.askBeforeRestart = false
        return settings
      }
    } catch {
      log.error("Cannot save \"Don't ask again\": \(String(describing: error), privacy: .public)")
    }
  }

  /// Lines for the chosen clones the pass could not build, and for a pass that did not run for anyone
  /// (`slug == "all"`: another pass, an edit or a delete holds `update.lock`).
  static func passProblems(_ decisions: [UpdateDecision], chosen: [String], instances: [Instance]) -> [String] {
    let lines = decisions.compactMap { decision -> String? in
      if decision.slug == UpdateDecision.everyClone { return UpdateFlowText.passProblem(decision) }
      guard chosen.contains(decision.slug) else { return nil }
      let name = instances.first { $0.slug.raw == decision.slug }?.name ?? decision.slug
      return UpdateFlowText.problem(decision, name: name)
    }
    return lines.reduce(into: []) { unique, line in if !unique.contains(line) { unique.append(line) } }
  }
}
