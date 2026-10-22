import AppKit
import Foundation
import InstanceBuilder
import Support
import Synchronization
import Testing
@testable import UI

private let mv2App = URL(fileURLWithPath: "/Applications/Claude mv2.app", isDirectory: true)

private func mv2Target(oldCopies: Bool = true, reusable: Bool = true) -> RemovalTarget {
  RemovalTarget(
    slug: slug("mv2"), name: "Claude mv2", bundleId: "com.imaxzone.claude.mv2", app: mv2App,
    profileDir: URL(fileURLWithPath: "/Users/u/Library/Application Support/ClaudeProfiles/mv2", isDirectory: true),
    backups: oldCopies ? [URL(fileURLWithPath: "/Users/u/data/backup/Claude mv2.app.20261001-120000")] : [],
    stagingBuilds: [], profileReusable: reusable)
}

/// Answers from canned values and records `target(…)`, `appOnlySize`, `profileSize` and `remove(…, mode)`.
final class FakeRemover: InstanceRemoving {
  let found: Result<RemovalTarget, RemovalError>
  let appBytes: Int64
  let profileBytes: Int64
  let report: RemovalReport
  private let calls = Mutex<[String]>([])

  init(found: Result<RemovalTarget, RemovalError> = .success(mv2Target()), appBytes: Int64 = 632_000_000,
       profileBytes: Int64 = 11_968_000_000, report: RemovalReport? = nil) {
    self.found = found
    self.appBytes = appBytes
    self.profileBytes = profileBytes
    self.report = report ?? RemovalReport(
      slug: "mv2", name: "Claude mv2", trashed: [mv2App], notTrashed: [], recordRemoved: true, problems: [])
  }

  var recorded: [String] { calls.withLock { $0 } }
  private func record(_ call: String) { calls.withLock { $0.append(call) } }

  func target(slug: String) async throws -> RemovalTarget {
    record("target(\(slug))")
    return try found.get()
  }

  func appOnlySize(of target: RemovalTarget) async -> Int64 {
    record("appOnlySize")
    return appBytes
  }

  func profileSize(of target: RemovalTarget) async -> Int64 {
    record("profileSize")
    return profileBytes
  }

  func remove(slug: String, mode: RemovalMode) async -> RemovalReport {
    record("remove(\(slug),\(mode.rawValue))")
    return report
  }
}

/// Records the dialog text when it opens and once both sizes are in, then answers `answer` (nil = «Отмена»).
@MainActor
final class FakeDeleteDialogs: DeleteDialogs {
  let answer: RemovalMode?
  private(set) var opened: [DeleteDialogText] = []
  private(set) var sized: DeleteDialogText?
  private(set) var problems: [(title: String, lines: [String])] = []

  init(answer: RemovalMode?) {
    self.answer = answer
  }

  func ask(_ model: DeleteDialogModel) async -> RemovalMode? {
    opened.append(model.text)
    for _ in 0..<400 where model.appOnlyBytes == nil || model.profileBytes == nil {
      try? await Task.sleep(for: .milliseconds(5))
    }
    sized = model.text
    if let answer { model.choice = answer }
    return answer
  }

  func showProblems(title: String, lines: [String]) async {
    problems.append((title, lines))
  }
}

/// Keeps the first question open until `answer(_:)`; any other question asked meanwhile is counted and cancelled at
/// once (so a bug shows as a count, never as a hang).
@MainActor
final class HeldDeleteDialogs: DeleteDialogs {
  private var waiting: CheckedContinuation<RemovalMode?, Never>?
  private(set) var asked = 0

  func ask(_ model: DeleteDialogModel) async -> RemovalMode? {
    asked += 1
    guard waiting == nil else { return nil }
    return await withCheckedContinuation { waiting = $0 }
  }

  func answer(_ mode: RemovalMode?) {
    waiting?.resume(returning: mode)
    waiting = nil
  }

  func showProblems(title: String, lines: [String]) async {}
}

@Suite(.russian) struct DeleteDialogTextTests {
  @Test func oneInstanceWithSizes() {
    let text = DeleteDialogText(name: "Claude mv2", app: mv2App, appOnlyBytes: 632_000_000,
                                profileBytes: 11_968_000_000, hasOldCopies: true, profileReusable: true)
    #expect(text.title == "Удалить «Claude mv2»?")
    #expect(text.lead == "Если приложение открыто, оно закроется. Всё удалённое попадёт в Корзину — до её очистки "
      + "можно вернуть.")
    #expect(text.appOnly.title == "Только приложение — 632 МБ")
    #expect(text.appOnly.removes
      == "Удалится: Claude mv2 из папки «Программы» и его старые версии, сохранённые при обновлениях")
    #expect(text.appOnly.keeps == "Останется: вход в аккаунт, настройки и кэш этого приложения (11,97 ГБ). Если снова "
      + "добавить приложение с тем же названием, оно откроется уже с вашим входом")
    #expect(text.everything.title == "Всё — 12,6 ГБ")
    #expect(text.everything.removes
      == "Удалится: приложение, вход в аккаунт, настройки, кэш и локальные файлы этого приложения на Mac")
    #expect(text.everything.keeps == "Останется: ваши чаты и проекты — они хранятся в аккаунте на claude.ai")
    #expect(text.footer == "Основной Claude и другие приложения это не затронет.")
    #expect(DeleteDialogText.cancelButton == "Отмена" && DeleteDialogText.deleteButton == "Удалить")
    #expect(DeleteDialogText.okButton == "ОК")
  }

  @Test func sizesShowAnEllipsisWhileComputing() {
    let none = DeleteDialogText(name: "Claude mv2", app: mv2App, appOnlyBytes: nil, profileBytes: nil,
                                hasOldCopies: true, profileReusable: true)
    #expect(none.appOnly.title == "Только приложение — …" && none.everything.title == "Всё — …")
    #expect(none.appOnly.keeps.hasPrefix("Останется: вход в аккаунт, настройки и кэш этого приложения (…). "))
    let appOnly = DeleteDialogText(name: "Claude mv2", app: mv2App, appOnlyBytes: 632_000_000, profileBytes: nil,
                                   hasOldCopies: true, profileReusable: true)
    #expect(appOnly.appOnly.size == "632 МБ" && appOnly.everything.size == "…")
  }

  @Test func withoutOldCopiesOrAReusableProfileThoseSentencesGo() {
    let text = DeleteDialogText(name: "Claude 2nd", app: URL(fileURLWithPath: "/Applications/Claude 2nd.app"),
                                appOnlyBytes: 1, profileBytes: 311_000_000, hasOldCopies: false, profileReusable: false)
    #expect(text.appOnly.removes == "Удалится: Claude 2nd из папки «Программы»")
    #expect(text.appOnly.keeps == "Останется: вход в аккаунт, настройки и кэш этого приложения (311 МБ)")
  }

  @Test func anEmptyProfileHasNoSizeAndAnAppElsewhereNamesItsFolder() {
    let text = DeleteDialogText(name: "Claude X", app: URL(fileURLWithPath: "/Volumes/Apps/Claude X.app"),
                                appOnlyBytes: 1_000_000, profileBytes: 0, hasOldCopies: false, profileReusable: false)
    #expect(text.appOnly.removes == "Удалится: Claude X из папки /Volumes/Apps")
    #expect(text.appOnly.keeps == "Останется: вход в аккаунт, настройки и кэш этого приложения")
    #expect(text.everything.size == "1 МБ")
  }

  /// «Всё» names the folder that goes with the app, abbreviated with `~`.
  @Test func everythingNamesTheProfileFolder() {
    let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)
    let profile = URL(fileURLWithPath: "/Users/u/Library/Application Support/ClaudeProfiles/mv2", isDirectory: true)
    let text = DeleteDialogText(name: "Claude mv2", app: mv2App, appOnlyBytes: 1, profileBytes: 1, hasOldCopies: false,
                                profileReusable: false, profileDir: profile, home: home)
    #expect(text.everything.detail == "Папка: ~/Library/Application Support/ClaudeProfiles/mv2")
    #expect(text.appOnly.detail == nil)
    let elsewhere = DeleteDialogText(name: "Claude mv2", app: mv2App, appOnlyBytes: 1, profileBytes: 1, hasOldCopies: false,
                                     profileReusable: false, profileDir: URL(fileURLWithPath: "/Volumes/ClaudeMultiAcc/mv2"), home: home)
    #expect(elsewhere.everything.detail == "Папка: /Volumes/ClaudeMultiAcc/mv2")
    let none = DeleteDialogText(name: "Claude mv2", app: mv2App, appOnlyBytes: 1, profileBytes: 1, hasOldCopies: false,
                                profileReusable: false)
    #expect(none.everything.detail == nil && none.appOnly.detail == nil)
  }

  @MainActor @Test func theDialogShowsTheTargetsProfileFolder() {
    let text = DeleteDialogText(DeleteDialogModel(target: mv2Target()), home: URL(fileURLWithPath: "/Users/u"))
    #expect(text.everything.detail == "Папка: ~/Library/Application Support/ClaudeProfiles/mv2")
    #expect(text.title == "Удалить «Claude mv2»?")
  }

  @Test func problemTitles() {
    let stopped = RemovalReport(slug: "mv2", name: "Claude mv2", trashed: [], notTrashed: [], recordRemoved: false,
                                problems: ["x"])
    let partial = RemovalReport(slug: "mv2", name: "Claude mv2", trashed: [mv2App], notTrashed: [], recordRemoved: true,
                                problems: ["x"])
    #expect(DeleteDialogText.problemTitle(stopped) == "Не удалось удалить «Claude mv2»")
    #expect(DeleteDialogText.problemTitle(partial) == "«Claude mv2» удалён не полностью")
  }
}

@MainActor
@Suite(.russian) struct DeleteFlowTests {
  @Test func cancelRemovesNothing() async {
    let remover = FakeRemover()
    let dialogs = FakeDeleteDialogs(answer: nil)
    let result = await DeleteFlow(remover: remover, dialogs: dialogs).delete(slug: "mv2")
    #expect(result == .cancelled)
    #expect(remover.recorded.first == "target(mv2)" && !remover.recorded.contains { $0.hasPrefix("remove") })
    #expect(dialogs.problems.isEmpty)
  }

  @Test func theDialogOpensWithAnEllipsisAndFillsInRealSizes() async {
    let dialogs = FakeDeleteDialogs(answer: nil)
    _ = await DeleteFlow(remover: FakeRemover(), dialogs: dialogs).delete(slug: "mv2")
    #expect(dialogs.opened.map(\.appOnly.size) == ["…"] && dialogs.opened.map(\.everything.size) == ["…"])
    #expect(dialogs.sized?.appOnly.title == "Только приложение — 632 МБ")
    #expect(dialogs.sized?.everything.title == "Всё — 12,6 ГБ")
  }

  @Test func theChosenModeIsRemovedAndACleanResultShowsNoAlert() async {
    let remover = FakeRemover()
    let dialogs = FakeDeleteDialogs(answer: .everything)
    let flow = DeleteFlow(remover: remover, dialogs: dialogs)
    let result = await flow.delete(slug: "mv2")
    #expect(result == .finished(remover.report))
    #expect(remover.recorded.last == "remove(mv2,everything)")
    #expect(dialogs.problems.isEmpty && flow.deleting.isEmpty)
  }

  @Test func problemsAreShownInOneAlert() async {
    let report = RemovalReport(slug: "mv2", name: "Claude mv2", trashed: [mv2App], notTrashed: [], recordRemoved: true,
                               problems: ["В Корзину перемещено: приложение «Claude mv2».", "Не перемещено: …"])
    let dialogs = FakeDeleteDialogs(answer: .appOnly)
    _ = await DeleteFlow(remover: FakeRemover(report: report), dialogs: dialogs).delete(slug: "mv2")
    #expect(dialogs.problems.count == 1)
    #expect(dialogs.problems.first?.title == "«Claude mv2» удалён не полностью")
    #expect(dialogs.problems.first?.lines == report.problems)
  }

  /// The alert leaves the main actor free, so a second click could arrive while the question is open.
  @Test func oneQuestionAtATime() async throws {
    let dialogs = HeldDeleteDialogs()
    let remover = FakeRemover()
    let flow = DeleteFlow(remover: remover, dialogs: dialogs)
    let first = Task { await flow.delete(slug: "mv2") }
    for _ in 0..<200 where dialogs.asked == 0 {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(dialogs.asked == 1)
    #expect(await flow.delete(slug: "mv2") == .cancelled)
    #expect(await flow.delete(slug: "work") == .cancelled)
    dialogs.answer(.appOnly)
    #expect(await first.value == .finished(remover.report))
    #expect(dialogs.asked == 1 && remover.recorded.filter { $0.hasPrefix("remove") } == ["remove(mv2,appOnly)"])
  }

  @Test func aRefusedTargetExplainsWhyWithoutAsking() async {
    let remover = FakeRemover(found: .failure(.notAClone(name: "Claude", kind: .official)))
    let dialogs = FakeDeleteDialogs(answer: .everything)
    let result = await DeleteFlow(remover: remover, dialogs: dialogs).delete(slug: "main")
    #expect(result == .refused("Основной Claude удалить нельзя"))
    #expect(dialogs.opened.isEmpty && remover.recorded == ["target(main)"])
    #expect(dialogs.problems.first?.title == DeleteDialogText.refusedTitle)
    #expect(dialogs.problems.first?.lines == ["Основной Claude удалить нельзя"])
  }
}
