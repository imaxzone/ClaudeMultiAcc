import Combine
import Foundation
import InstanceBuilder
import os
import Support

/// «Добавить» (empty fields, «Создать») or «Изменить…» of one clone (prefilled; «Переустановить» while nothing is
/// changed, «Сохранить» once something is).
public enum InstanceEditorMode: Hashable, Sendable {
  case add
  case edit(slug: String)
}

/// Where a message is shown: under a field or below both.
public enum InstanceEditorField: Hashable, Sendable {
  case name, badge, general
}

public enum InstanceEditorStep: Equatable, Sendable {
  case signing, building, confirming, installing, opening, closing, reopening
}

public enum InstanceEditorPhase: Equatable, Sendable {
  case loading
  case editing
  case working(InstanceEditorStep)
  /// The reason; the fields are editable again and the button retries.
  case failed(String)
  case done(title: String, detail: String?)
  /// «Изменить…» of something that cannot be edited (or is gone); the reason.
  case unavailable(String)
}

/// Makes sure a permanent signing identity exists (creating it when it can) and returns it; throws when there is none.
public typealias InstanceEditorEnsureSigning = @Sendable () async throws -> SigningIdentity

/// State of the «Изменить…» / «Добавить» window. «Добавить»: signing → staging build → confirmation → (a leftover
/// profile to the Trash when asked) → install → open. «Изменить…»: signing → `EditInstance` (build, close, swap or
/// rename, reopen) → on the done screen «Обновить Док» when clicked. With nothing changed the same flow reinstalls the
/// clone from the current Claude.
@MainActor
public final class InstanceEditorViewModel: ObservableObject {
  static var noSigning: String { InstanceEditorText.noSigning }

  @Published public var name = "" { didSet { if name != oldValue { nameEdited() } } }
  @Published public var badge = "" { didSet { if badge != oldValue { badgeEdited() } } }
  @Published public internal(set) var phase: InstanceEditorPhase = .loading
  @Published public internal(set) var isRunning = false
  @Published private(set) var problems: [InstanceEditorField: [String]] = [:]
  /// «Добавить»: the typed name when a removed app of that name left its profile (sign-in, settings) on this Mac.
  @Published public private(set) var leftoverFor: String?
  /// «Обновить Док» on the done screen.
  @Published public internal(set) var dockRefresh: DockRefreshState = .idle
  /// The answer to the leftover question; back to «войти как раньше» whenever another leftover is found.
  @Published public var leftoverChoice: LeftoverProfileChoice = .signInAsBefore

  public let mode: InstanceEditorMode
  /// Runs after a successful add or edit with the new registry entry.
  public var onFinish: (@MainActor (Instance) -> Void)?

  let services: any InstanceEditorServices
  let dialogs: any InstanceEditorDialogs
  private let ensureSigning: InstanceEditorEnsureSigning
  let restartDock: InstanceEditorRefreshDock
  /// The running or last «Изменить…» rebuilds the clone unchanged.
  var reinstalling = false
  private(set) var existing: [Instance] = []
  private(set) var leftoverSlug: String?
  private(set) var original: Instance?
  private var loadError: String?
  private var badgeTyped = false
  private var suggesting = false
  private var touched = false
  private var submitting = false
  let log = AppLog.logger("instance-editor")

  /// `refreshDock` runs only on a click of «Обновить Док», with the edited clone's app (default: touch,
  /// `lsregister -f`, the Dock's icon cache file removed, `killall Dock`).
  public init(
    mode: InstanceEditorMode, services: any InstanceEditorServices, dialogs: any InstanceEditorDialogs,
    ensureSigning: @escaping InstanceEditorEnsureSigning,
    refreshDock: @escaping InstanceEditorRefreshDock = InstanceEditorDock.restart()
  ) {
    self.mode = mode
    self.services = services
    self.dialogs = dialogs
    self.ensureSigning = ensureSigning
    restartDock = refreshDock
  }

  public func load() async {
    do {
      existing = try await services.existingInstances()
      loadError = nil
    } catch {
      log.error("cannot read instances: \(String(describing: error), privacy: .public)")
      existing = []
      loadError = InstanceEditorText.loadFailed
    }
    guard case .edit(let slug) = mode else {
      phase = .editing
      revalidate()
      return
    }
    await loadForEdit(slug: slug)
  }

  private func loadForEdit(slug: String) async {
    guard loadError == nil, let instance = existing.first(where: { $0.slug.raw == slug }) else {
      phase = .unavailable(loadError ?? EditInstanceError.notFound(slug).userMessage)
      return
    }
    if let refusal = EditInstance.refusal(for: instance) {
      phase = .unavailable(EditInstanceError.notEditable(name: instance.name, reason: refusal).userMessage)
      return
    }
    original = instance
    name = instance.name
    badge = instance.badge ?? ""
    touched = true
    isRunning = await services.isRunning(instance)
    phase = .editing
    revalidate()
  }

  // MARK: Texts

  public var windowTitle: String {
    switch mode {
    case .add: InstanceEditorText.addTitle
    case .edit: original.map { InstanceEditorText.editTitle(name: $0.name) } ?? InstanceEditorText.editTitlePlain
    }
  }

  public var submitTitle: String {
    guard mode != .add else { return InstanceEditorText.create }
    return isReinstall ? InstanceEditorText.reinstall : InstanceEditorText.save
  }

  /// Under the icon: the name as the Dock will show it; nil while empty.
  public var previewName: String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  public var previewBadge: String { badge.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The line above the buttons while nothing runs.
  public var note: String? {
    guard phase == .editing else { return nil }
    guard let original else {
      return InstanceEditorText.addNote(signedIn: leftoverFor != nil && leftoverChoice == .signInAsBefore)
    }
    if isReinstall {
      let closing = isRunning ? [InstanceEditorText.closingNote(name: original.name)] : []
      return ([InstanceEditorText.reinstallNote(name: original.name)] + closing + [InstanceEditorText.signedInNote])
        .joined(separator: " ")
    }
    let closing = isRunning ? InstanceEditorText.closingNote(name: original.name) : InstanceEditorText.rebuildNote
    let dock = renamesApp ? [InstanceEditorText.dockNote] : []
    return ([closing, InstanceEditorText.signedInNote] + dock).joined(separator: " ")
  }

  /// «Изменить…» with the name, label and file name as they are: the button rebuilds the clone from the current
  /// Claude (a fresh icon) instead of saving.
  public var isReinstall: Bool {
    guard let original else { return false }
    let draft = InstanceDraft(name: name, badge: badge)
    return draft.name == original.name && draft.badge == (original.badge ?? "") && originalFileName == draft.name
  }

  /// «Изменить…»: the app's file gets the new name (the Dock loses a pinned icon of it).
  var renamesApp: Bool {
    let draft = InstanceDraft(name: name, badge: badge)
    guard let fileName = originalFileName, !draft.name.isEmpty else { return false }
    return draft.name != fileName
  }

  /// The edited app's file name without `.app`.
  private var originalFileName: String? {
    original?.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
  }

  public var progressText: String? {
    guard case .working(let step) = phase else { return nil }
    let shown = previewName ?? ""
    switch step {
    case .signing: return InstanceEditorText.signing
    case .building:
      if reinstalling { return InstanceEditorText.reinstalling(shown) }
      return InstanceEditorText.building(shown, rebuild: original != nil)
    case .confirming: return InstanceEditorText.confirming
    case .installing: return InstanceEditorText.installing
    case .opening: return InstanceEditorText.opening(shown)
    case .closing: return InstanceEditorText.closing(original?.name ?? shown)
    case .reopening: return InstanceEditorText.reopening(shown)
    }
  }

  public var failureTitle: String {
    guard original != nil else { return InstanceEditorText.createFailed }
    return reinstalling ? InstanceEditorText.reinstallFailed : InstanceEditorText.saveFailed
  }

  // MARK: State

  /// Messages under `field`. «Добавить» shows none until something was typed.
  public func messages(for field: InstanceEditorField) -> [String] {
    guard touched || field == .general else { return [] }
    return problems[field] ?? []
  }

  public var isBusy: Bool {
    if case .working = phase { return true }
    return false
  }

  public var fieldsLocked: Bool {
    switch phase {
    case .editing, .failed: false
    default: true
    }
  }

  /// Valid fields; «Изменить…» without changes reinstalls.
  public var canSubmit: Bool {
    guard !fieldsLocked, problems.values.allSatisfy(\.isEmpty) else { return false }
    let draft = InstanceDraft(name: name, badge: badge)
    return !draft.name.isEmpty && !draft.badge.isEmpty
  }

  // MARK: Editing

  private func nameEdited() {
    touched = true
    if mode == .add, !badgeTyped {
      suggesting = true
      badge = NewInstanceRequest.suggestedBadge(forAppName: name)
      suggesting = false
    }
    revalidate()
  }

  private func badgeEdited() {
    if !suggesting {
      touched = true
      badgeTyped = !badge.isEmpty
    }
    revalidate()
  }

  func revalidate() {
    guard !suggesting else { return }
    var result: [InstanceEditorField: [String]] = [:]
    if let loadError { result[.general] = [loadError] }
    let draft = InstanceDraft(name: name, badge: badge)
    for problem in draft.problems(existing: existing, editing: original?.slug) {
      result[problem.field == .name ? .name : .badge, default: []].append(problem.message)
    }
    if result[.name] == nil {
      for (field, message) in placementProblems(draft) where !(result[field] ?? []).contains(message) {
        result[field, default: []].append(message)
      }
    }
    problems = result
    findLeftoverProfile(draft, nameIsValid: result[.name] == nil)
  }

  /// «Добавить»: a profile folder of the hidden slug that no instance uses means the name was used before.
  private func findLeftoverProfile(_ draft: InstanceDraft, nameIsValid: Bool) {
    var slug: String?
    if original == nil, mode == .add, nameIsValid, !draft.name.isEmpty {
      let candidate = services.newRequest(name: draft.name, badge: draft.badge, existing: existing).slug
      if services.leftoverProfile(slug: candidate, existing: existing) != nil { slug = candidate }
    }
    if slug != leftoverSlug { leftoverChoice = .signInAsBefore }
    leftoverSlug = slug
    leftoverFor = slug == nil ? nil : draft.name
  }

  /// Where the app would land: an existing app of that name, or (never expected) a clash of the hidden identity.
  private func placementProblems(_ draft: InstanceDraft) -> [(InstanceEditorField, String)] {
    if let original {
      guard let target = EditInstance.renameTarget(of: original, to: draft.name), services.appExists(target) else { return [] }
      return [(.name, EditInstanceError.targetExists(target.path).userMessage)]
    }
    guard !draft.name.isEmpty else { return [] }
    let request = services.newRequest(name: draft.name, badge: draft.badge, existing: existing)
    return services.validate(request, existing: existing).compactMap { error -> (InstanceEditorField, String)? in
      switch error {
      case .targetExists, .duplicateAppPath: (.name, error.message)
      case .badSlug, .duplicateSlug, .duplicateBundleId, .duplicateProfileDir: (.general, error.message)
      case .emptyName, .nameTooLong, .invalidName, .badBadge, .badEmail, .storeCorrupt: nil
      }
    }
  }

  // MARK: Submit

  /// «Создать», «Сохранить» or «Переустановить».
  public func submit() async {
    guard canSubmit, !submitting else { return }
    submitting = true
    defer { submitting = false }
    if original == nil { await create() } else { await save() }
  }

  func show(_ stage: EditStage) {
    switch stage {
    case .building: phase = .working(.building)
    case .closing: phase = .working(.closing)
    case .installing: phase = .working(.installing)
    case .reopening: phase = .working(.reopening)
    }
  }

  /// The permanent identity from `ensureSigning`; nil (and `.failed`) when there is none.
  func prepareSigning() async -> SigningIdentity? {
    phase = .working(.signing)
    do {
      let identity = try await ensureSigning()
      guard identity != .adhoc else {
        log.error("ensureSigning gave an ad hoc identity")
        phase = .failed(Self.noSigning)
        return nil
      }
      return identity
    } catch {
      log.error("signing unavailable: \(String(describing: error), privacy: .public)")
      phase = .failed(Self.noSigning)
      return nil
    }
  }

  func replaceOriginal(with instance: Instance) {
    original = instance
    existing = existing.map { $0.slug == instance.slug ? instance : $0 }
  }

  func finish(_ instance: Instance, title: String, detail: String?) {
    phase = .done(title: title, detail: detail)
    onFinish?(instance)
  }

  /// The text for any failure of the window's flows.
  static func text(for error: any Error) -> String {
    switch error {
    case EditInstanceError.notVerified(let step?):
      InstanceEditorText.notVerified(step: BuildSummary.stepTitle(step))
    case let error as EditInstanceError: error.userMessage
    default: UserMessage.text(for: error)
    }
  }
}
