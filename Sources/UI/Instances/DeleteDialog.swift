import Foundation
import InstanceBuilder
import Observation
import os
import Support

/// The open «Удалить «…»?» question: the clone, the chosen mode and the sizes as they come in.
@MainActor
@Observable
public final class DeleteDialogModel {
  public let target: RemovalTarget
  /// The first option is the default.
  public var choice: RemovalMode = .appOnly
  /// The app with its old copies; nil while measuring.
  public var appOnlyBytes: Int64?
  /// The profile; nil while measuring.
  public var profileBytes: Int64?

  public init(target: RemovalTarget) {
    self.target = target
  }

  public var text: DeleteDialogText { DeleteDialogText(self) }
}

/// The question and the problem alert; `AlertDeleteDialogs` on the real machine, fakes in tests.
@MainActor
public protocol DeleteDialogs: AnyObject {
  /// Asks what to remove; nil on «Отмена». The model's sizes fill in while the question is open.
  func ask(_ model: DeleteDialogModel) async -> RemovalMode?
  func showProblems(title: String, lines: [String]) async
}

/// How one «Удалить «…»…» ended.
public enum DeleteFlowResult: Sendable, Equatable {
  case cancelled
  /// The clone cannot be removed (official, CLI-only, gone, shared folders); the reason was shown.
  case refused(String)
  /// The removal ran; reload the app list (`report.recordRemoved`). Problems, if any, were shown.
  case finished(RemovalReport)
}

/// «Удалить «Claude mv2»…» from a tile's action menu: asks «только приложение» or «всё» with real sizes, removes
/// to the Trash and shows an alert only when something went wrong.
@MainActor
@Observable
public final class DeleteFlow {
  /// Slugs being removed right now (quitting the app can take up to 30 s); the menu may dim their tiles.
  public private(set) var deleting: Set<String> = []
  /// A question (or the reason it cannot be asked) is on screen; the main actor stays free meanwhile.
  private var asking = false

  private let remover: any InstanceRemoving
  private let dialogs: any DeleteDialogs
  private let log = AppLog.logger("delete-flow")

  public init(remover: any InstanceRemoving, dialogs: any DeleteDialogs) {
    self.remover = remover
    self.dialogs = dialogs
  }

  /// Asks, removes and reports. A request while another question is open, or for a clone already being removed,
  /// is `.cancelled` without a second dialog.
  @discardableResult
  public func delete(slug: String) async -> DeleteFlowResult {
    guard !asking, !deleting.contains(slug) else { return .cancelled }
    asking = true
    let target: RemovalTarget
    do {
      target = try await remover.target(slug: slug)
    } catch {
      let message = (error as? RemovalError)?.userMessage ?? UserMessage.text(for: error)
      log.error("cannot remove \(slug, privacy: .public): \(String(describing: error), privacy: .public)")
      await dialogs.showProblems(title: DeleteDialogText.refusedTitle, lines: [message])
      asking = false
      return .refused(message)
    }
    let model = DeleteDialogModel(target: target)
    let measuring = measure(model)
    let choice = await dialogs.ask(model)
    measuring.forEach { $0.cancel() }
    asking = false
    guard let choice else { return .cancelled }
    deleting.insert(slug)
    defer { deleting.remove(slug) }
    let report = await remover.remove(slug: slug, mode: choice)
    if !report.problems.isEmpty {
      await dialogs.showProblems(title: DeleteDialogText.problemTitle(report), lines: report.problems)
    }
    return .finished(report)
  }

  /// Both sizes in parallel, each shown as soon as it is known.
  private func measure(_ model: DeleteDialogModel) -> [Task<Void, Never>] {
    let target = model.target
    let remover = remover
    return [
      Task { [weak model] in
        let bytes = await remover.appOnlySize(of: target)
        if !Task.isCancelled { model?.appOnlyBytes = bytes }
      },
      Task { [weak model] in
        let bytes = await remover.profileSize(of: target)
        if !Task.isCancelled { model?.profileBytes = bytes }
      },
    ]
  }
}

extension DeleteFlow {
  /// The real machine: `InstanceRemover.live` (its own `InstanceStore(paths:)`, `NSRunningApplication` quit
  /// requests and running checks, the Finder Trash, `lsregister -u` and `lsappinfo` through `runner`, `update.lock`,
  /// `instances.log`) and `NSAlert`s.
  public static func live(paths: Paths, runner: ProcessRunning = SystemProcessRunner()) -> DeleteFlow {
    DeleteFlow(remover: InstanceRemover.live(paths: paths, runner: runner), dialogs: AlertDeleteDialogs())
  }
}
