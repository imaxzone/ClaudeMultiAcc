import AppKit
import Foundation
import InstanceBuilder
import Support
import Testing
@testable import UI

@MainActor
@Suite(.russian) struct NewInstanceEditorViewModelTests {
  private func four() throws -> [Instance] {
    let root = URL(fileURLWithPath: "/tmp/root")
    struct File: Decodable { let instances: [Instance] }
    return try JSONCoding.decoder.decode(File.self, from: Data(try fixtureText("instances-four.json", root: root).utf8)).instances
  }

  private func model(
    _ mode: InstanceEditorMode, _ services: EditorFakeServices, _ dialogs: EditorFakeDialogs = EditorFakeDialogs(),
    signing: SigningProbe = SigningProbe()
  ) async -> InstanceEditorViewModel {
    let model = InstanceEditorViewModel(
      mode: mode, services: services, dialogs: dialogs, ensureSigning: signing.closure, refreshDock: DockProbe().closure)
    await model.load()
    return model
  }

  // MARK: Add

  @Test func anEmptyAddWindowShowsNoMessagesAndCannotCreate() async throws {
    let m = await model(.add, EditorFakeServices(existing: try four()))
    #expect(m.phase == .editing && m.windowTitle == "Новое приложение" && m.submitTitle == "Создать")
    for field in [InstanceEditorField.name, .badge, .general] { #expect(m.messages(for: field).isEmpty) }
    #expect(!m.canSubmit && m.previewName == nil)
    #expect(m.note?.contains("1–3 минуты") == true)
  }

  @Test func theLabelFollowsTheNameUntilItIsTyped() async throws {
    let m = await model(.add, EditorFakeServices(existing: try four()))
    m.name = "Claude mv2"
    #expect(m.badge == "mv2" && m.previewName == "Claude mv2" && m.canSubmit)
    m.badge = "M2"
    m.name = "Claude mv3"
    #expect(m.badge == "M2")
    m.badge = ""
    m.name = "Claude Работа"
    #expect(m.badge == "Раб")
  }

  @Test func messagesSitUnderTheirFields() async throws {
    let m = await model(.add, EditorFakeServices(existing: try four()))
    m.name = "claude work"
    #expect(m.messages(for: .name) == ["«Claude Work» уже есть — выберите другое название"])
    m.name = "Claude mv2"
    m.badge = "Работа"
    #expect(m.messages(for: .name).isEmpty)
    #expect(m.messages(for: .badge) == ["Не больше 4 знаков, сейчас 6"])
    #expect(!m.canSubmit)
    m.name = ""
    #expect(m.messages(for: .name) == ["Введите название"])
  }

  @Test func anAppAlreadyInApplicationsIsReportedUnderTheName() async throws {
    let root = try makeTempDir()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Claude Taken.app"), withIntermediateDirectories: true)
    var knobs = EditorFakeServices.Knobs()
    knobs.applicationsDir = root
    let m = await model(.add, EditorFakeServices(existing: try four(), knobs))
    m.name = "Claude Taken"
    #expect(m.messages(for: .name) == ["Claude Taken.app уже существует в «Программах»"])
    #expect(!m.canSubmit)
  }

  /// The identity comes from `ensureSigning` (the services' own read-only check finds none here).
  @Test func createBuildsAsksInstallsAndOpens() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.identity = nil
    let services = EditorFakeServices(existing: try four(), knobs)
    let dialogs = EditorFakeDialogs(confirm: true)
    let signing = SigningProbe()
    let m = await model(.add, services, dialogs, signing: signing)
    var finished: [String] = []
    m.onFinish = { finished.append($0.name) }
    m.name = "Claude mv2"
    #expect(m.leftoverFor == nil)
    await m.submit()
    #expect(signing.count == 1 && dialogs.confirmations == 1)
    #expect(services.recorded == ["build(mv2,Claude mv2,mv2)", "install(mv2)", "open(Claude mv2.app)"])
    #expect(m.phase == .done(title: "«Claude mv2» готово", detail: "Оно открывается — войдите в аккаунт в новом окне."))
    #expect(finished == ["Claude mv2"])
  }

  @Test func aDeclinedInstallRemovesTheBuildAndUnlocksTheFields() async throws {
    let services = EditorFakeServices(existing: try four())
    let m = await model(.add, services, EditorFakeDialogs(confirm: false))
    m.name = "Claude mv2"
    await m.submit()
    #expect(services.recorded == ["build(mv2,Claude mv2,mv2)", "discard(mv2)"])
    #expect(m.phase == .editing && !m.fieldsLocked && m.canSubmit)
  }

  /// A removed app of the same name left its profile: the window asks while the name is typed, «войти как раньше»
  /// first; «начать с чистого» sends the folder to the Trash only once the install is confirmed.
  @Test(arguments: [
    (LeftoverProfileChoice.signInAsBefore, ["build(mv2,Claude mv2,mv2)", "install(mv2)", "open(Claude mv2.app)"],
     "Оно открывается с прежним входом в аккаунт."),
    (.startClean, ["build(mv2,Claude mv2,mv2)", "trashLeftover(mv2)", "install(mv2)", "open(Claude mv2.app)"],
     "Оно открывается — войдите в аккаунт в новом окне."),
  ])
  func aLeftoverProfileIsAskedAboutInTheWindow(choice: LeftoverProfileChoice, calls: [String], detail: String) async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.leftover = true
    let services = EditorFakeServices(existing: try four(), knobs)
    let m = await model(.add, services)
    #expect(m.leftoverFor == nil)
    m.name = "Claude mv2"
    #expect(m.leftoverFor == "Claude mv2" && m.leftoverChoice == .signInAsBefore)
    #expect(m.note == "Сборка занимает 1–3 минуты, потом приложение откроется уже со входом в аккаунт.")
    m.leftoverChoice = choice
    await m.submit()
    #expect(services.recorded == calls)
    #expect(m.phase == .done(title: "«Claude mv2» готово", detail: detail))
  }

  @Test func theLeftoverQuestionFollowsTheName() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.leftover = true
    let m = await model(.add, EditorFakeServices(existing: try four(), knobs))
    m.name = "Claude mv2"
    m.leftoverChoice = .startClean
    #expect(m.note == "Сборка занимает 1–3 минуты, потом приложение откроется — войдите в нём в аккаунт.")
    m.name = "Claude mv3"
    #expect(m.leftoverFor == "Claude mv3" && m.leftoverChoice == .signInAsBefore)
    m.name = "claude work"
    #expect(m.leftoverFor == nil)
    m.name = ""
    #expect(m.leftoverFor == nil)
  }

  /// A declined install trashes nothing, whatever was chosen.
  @Test func aDeclinedInstallKeepsTheLeftoverProfile() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.leftover = true
    let services = EditorFakeServices(existing: try four(), knobs)
    let m = await model(.add, services, EditorFakeDialogs(confirm: false))
    m.name = "Claude mv2"
    m.leftoverChoice = .startClean
    await m.submit()
    #expect(services.recorded == ["build(mv2,Claude mv2,mv2)", "discard(mv2)"])
  }

  /// Without signing the window says so in one line: no Terminal command, no ad hoc build.
  @Test func withoutSigningNothingIsBuilt() async throws {
    let failing = EditorFakeServices(existing: try four())
    let m1 = await model(.add, failing, signing: SigningProbe(fails: true))
    m1.name = "Claude mv2"
    await m1.submit()
    #expect(m1.phase == .failed(InstanceEditorViewModel.noSigning) && failing.recorded.isEmpty)

    let adhoc = EditorFakeServices(existing: try four())
    let m2 = await model(.add, adhoc, signing: SigningProbe(.adhoc))
    m2.name = "Claude mv2"
    await m2.submit()
    #expect(m2.phase == .failed(InstanceEditorViewModel.noSigning) && adhoc.recorded.isEmpty)
    #expect(!InstanceEditorViewModel.noSigning.contains("Терминал") && !InstanceEditorViewModel.noSigning.contains("команд"))
    #expect(!m2.fieldsLocked && m2.canSubmit)
  }

  @Test func anUnverifiedBuildNamesTheStepAndCanBeRetried() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.verified = false
    let services = EditorFakeServices(existing: try four(), knobs)
    let m = await model(.add, services)
    m.name = "Claude mv2"
    await m.submit()
    #expect(m.phase == .failed("Сборка не прошла проверку на шаге «Проверка подписи» — ничего не изменено"))
    #expect(services.recorded == ["build(mv2,Claude mv2,mv2)", "discard(mv2)"])
    #expect(m.canSubmit && m.failureTitle == "Не удалось создать")
  }

  @Test func installAndBuildErrorsAreRussian() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.installError = InstallError.running("com.imaxzone.claude.mv2")
    let services = EditorFakeServices(existing: try four(), knobs)
    let m = await model(.add, services)
    m.name = "Claude mv2"
    await m.submit()
    #expect(m.phase == .failed(UserMessage.text(for: InstallError.running("com.imaxzone.claude.mv2"))))
    #expect(services.recorded.last == "discard(mv2)")

    var broken = EditorFakeServices.Knobs()
    broken.buildError = BuilderError.vendorUpdateActive
    let m2 = await model(.add, EditorFakeServices(existing: try four(), broken))
    m2.name = "Claude mv2"
    await m2.submit()
    #expect(m2.phase == .failed(UserMessage.text(for: BuilderError.vendorUpdateActive)))
  }

  @Test func aFailedOpenStillFinishes() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.openFails = true
    let m = await model(.add, EditorFakeServices(existing: try four(), knobs))
    m.name = "Claude mv2"
    await m.submit()
    #expect(m.phase == .done(title: "«Claude mv2» готово", detail: "Откройте его из «Программ» и войдите в аккаунт."))
  }

  // MARK: Edit

  /// Unchanged it offers «Переустановить»; a change turns the button into «Сохранить».
  @Test func editIsPrefilledAndWarnsThatARunningAppCloses() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.running = true
    let m = await model(.edit(slug: "work"), EditorFakeServices(existing: try four(), knobs))
    #expect(m.name == "Claude Work" && m.badge == "W" && m.isRunning)
    #expect(m.windowTitle == "Изменить «Claude Work»" && m.submitTitle == "Переустановить" && m.canSubmit)
    m.badge = "Wk"
    #expect(m.submitTitle == "Сохранить")
    #expect(m.note == "Claude Work закроется на пару секунд, чтобы применить изменения, и откроется снова. "
      + "Вход в аккаунт сохранится.")
    #expect(m.canSubmit && m.messages(for: .name).isEmpty)
    #expect(m.leftoverFor == nil)
  }

  /// A new name renames the app's file: a pinned Dock icon has to be pinned again.
  @Test func aRenameSaysToPinTheDockIconAgain() async throws {
    let m = await model(.edit(slug: "work"), EditorFakeServices(existing: try four()))
    m.badge = "J"
    #expect(m.note == "Приложение пересоберётся с новым названием и надписью. Вход в аккаунт сохранится.")
    m.name = "Claude Job"
    #expect(m.note == "Приложение пересоберётся с новым названием и надписью. Вход в аккаунт сохранится. "
      + "Если оно закреплено в Доке, после сохранения закрепите его заново.")
  }

  /// Its own name in another letter case is no clash, and it is a change (the file is renamed).
  @Test func editKeepsItsOwnNameFree() async throws {
    let m = await model(.edit(slug: "work"), EditorFakeServices(existing: try four()))
    m.name = "CLAUDE WORK"
    #expect(m.messages(for: .name).isEmpty && m.canSubmit)
    m.name = "Claude 2nd"
    #expect(m.messages(for: .name) == ["«Claude 2nd» уже есть — выберите другое название"])
  }

  @Test func editReportsAnExistingAppAtTheNewName() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.existingApps = ["/tmp/root/Applications/Claude Job.app"]
    let m = await model(.edit(slug: "work"), EditorFakeServices(existing: try four(), knobs))
    m.name = "Claude Job"
    #expect(m.messages(for: .name) == ["«Claude Job.app» уже есть в «Программах» — выберите другое название"])
    #expect(!m.canSubmit)
  }

  @Test func saveRunsTheEditAndShowsItsStages() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.running = true
    let services = EditorFakeServices(existing: try four(), knobs)
    let signing = SigningProbe()
    let m = await model(.edit(slug: "work"), services, signing: signing)
    var finished: [String] = []
    m.onFinish = { finished.append("\($0.name)/\($0.badge ?? "-")") }
    m.name = "Claude Job"
    m.badge = "J"
    await m.submit()
    #expect(signing.count == 1)
    #expect(services.recorded == ["edit(work,Claude Job,J,certificate)"])
    #expect(m.phase == .done(title: "Сохранено", detail: "«Claude Job» снова открыто."))
    #expect(finished == ["Claude Job/J"] && m.windowTitle == "Изменить «Claude Job»")
  }

  @Test func aFailedEditShowsWhyAndCanBeRetried() async throws {
    var knobs = EditorFakeServices.Knobs()
    knobs.editError = EditInstanceError.stillRunning("Claude Work")
    let m = await model(.edit(slug: "work"), EditorFakeServices(existing: try four(), knobs))
    m.badge = "Wk"
    await m.submit()
    #expect(m.phase == .failed(EditInstanceError.stillRunning("Claude Work").userMessage))
    #expect(m.failureTitle == "Не удалось сохранить" && m.canSubmit)
  }

  @Test(arguments: [
    ("second", "«Claude 2nd» собрано старым способом — изменить его здесь нельзя"),
    ("main", "Основной Claude изменить нельзя"), ("alt", "У «Claude (alt CLI)» нет приложения — менять нечего"),
    ("nope", "Этого приложения уже нет в списке"),
  ])
  func editOfSomethingNotEditableSaysWhy(slug: String, message: String) async throws {
    let m = await model(.edit(slug: slug), EditorFakeServices(existing: try four()))
    #expect(m.phase == .unavailable(message) && !m.canSubmit)
  }
}
