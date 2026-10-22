import Foundation
import InstanceBuilder
import Support
import Synchronization
import Testing
@testable import UI

/// The `refreshDock` of a test: records the apps of each call and fails when asked. Never runs `killall`.
final class DockProbe: Sendable {
  private let calls = Mutex<[[URL]]>([])
  let fails: Bool

  init(fails: Bool = false) {
    self.fails = fails
  }

  var count: Int { calls.withLock { $0.count } }
  /// The apps given to each call.
  var apps: [[URL]] { calls.withLock { $0 } }

  var closure: InstanceEditorRefreshDock {
    { [self] apps in
      calls.withLock { $0.append(apps) }
      if fails { throw CocoaError(.featureUnsupported) }
    }
  }
}

/// «Изменить…» with nothing changed is «Переустановить»; the done screen offers to restart the Dock (only on a click).
@MainActor
@Suite(.russian) struct InstanceEditorReinstallTests {
  private static let reinstallNote = "Соберёт «Claude Work» заново из текущего Claude — с новой иконкой."

  private func four() throws -> [Instance] {
    let root = URL(fileURLWithPath: "/tmp/root")
    struct File: Decodable { let instances: [Instance] }
    return try JSONCoding.decoder.decode(File.self, from: Data(try fixtureText("instances-four.json", root: root).utf8)).instances
  }

  private func model(
    _ services: EditorFakeServices, mode: InstanceEditorMode = .edit(slug: "work"),
    signing: SigningProbe = SigningProbe(), dock: DockProbe = DockProbe()
  ) async -> InstanceEditorViewModel {
    let model = InstanceEditorViewModel(
      mode: mode, services: services, dialogs: EditorFakeDialogs(), ensureSigning: signing.closure,
      refreshDock: dock.closure)
    await model.load()
    return model
  }

  private func services(running: Bool = false, editError: (any Error & Sendable)? = nil) throws -> EditorFakeServices {
    var knobs = EditorFakeServices.Knobs()
    knobs.running = running
    knobs.editError = editError
    return EditorFakeServices(existing: try four(), knobs)
  }

  // MARK: The button

  @Test func anUnchangedCloneOffersReinstall() async throws {
    let m = await model(try services())
    #expect(m.submitTitle == "Переустановить" && m.isReinstall && m.canSubmit)
    #expect(m.note == "\(Self.reinstallNote) Вход в аккаунт сохранится.")
  }

  @Test func aChangeTurnsTheButtonIntoSaveAndBack() async throws {
    let m = await model(try services())
    m.badge = "Wk"
    #expect(m.submitTitle == "Сохранить" && !m.isReinstall && m.canSubmit)
    m.badge = " W "
    #expect(m.submitTitle == "Переустановить" && m.canSubmit)
    m.name = "Claude Job"
    #expect(m.submitTitle == "Сохранить" && m.canSubmit)
    #expect(m.note?.hasPrefix("Приложение пересоберётся с новым названием и надписью.") == true)
  }

  @Test func invalidInputCanBeNeitherSavedNorReinstalled() async throws {
    let m = await model(try services())
    m.badge = "Работа"
    #expect(m.submitTitle == "Сохранить" && !m.canSubmit)
    m.badge = ""
    #expect(m.submitTitle == "Сохранить" && !m.canSubmit)
    m.badge = "W"
    m.name = "Claude 2nd"
    #expect(m.submitTitle == "Сохранить" && !m.canSubmit)
    m.name = ""
    #expect(!m.canSubmit)
  }

  /// A running clone still says it closes for a few seconds.
  @Test func aRunningCloneStillSaysItClosesForAMoment() async throws {
    let m = await model(try services(running: true))
    #expect(m.note == "\(Self.reinstallNote) Claude Work закроется на пару секунд, чтобы применить изменения, и откроется "
      + "снова. Вход в аккаунт сохранится.")
  }

  // MARK: The reinstall

  @Test func reinstallSignsAndRunsTheEditWithTheFlag() async throws {
    let services = try services(running: true)
    let signing = SigningProbe()
    let m = await model(services, signing: signing)
    var finished: [String] = []
    m.onFinish = { finished.append("\($0.name)/\($0.badge ?? "-")") }
    await m.submit()
    #expect(signing.count == 1)
    #expect(services.recorded == ["edit(work,Claude Work,W,certificate,reinstall)"])
    #expect(m.phase == .done(title: "Переустановлено", detail: "«Claude Work» снова открыто."))
    #expect(finished == ["Claude Work/W"])
  }

  @Test func aSaveIsNoReinstall() async throws {
    let services = try services()
    let m = await model(services)
    m.badge = "Wk"
    await m.submit()
    #expect(services.recorded == ["edit(work,Claude Work,Wk,certificate)"])
    #expect(m.phase == .done(title: "Сохранено", detail: nil))
  }

  @Test func theProgressLineSaysReinstalling() async throws {
    let m = await model(try services())
    m.reinstalling = true
    m.phase = .working(.building)
    #expect(m.progressText == "Переустанавливаю «Claude Work»… обычно 1–3 минуты")
    m.reinstalling = false
    #expect(m.progressText == "Пересобираю «Claude Work»… обычно 1–3 минуты")
  }

  @Test func aFailedReinstallSaysSoAndCanBeRetried() async throws {
    let m = await model(try services(editError: EditInstanceError.stillRunning("Claude Work")))
    await m.submit()
    #expect(m.phase == .failed(EditInstanceError.stillRunning("Claude Work").userMessage))
    #expect(m.failureTitle == "Не удалось переустановить" && m.submitTitle == "Переустановить" && m.canSubmit)
  }

  // MARK: Dock

  @Test func theDoneScreenRestartsTheDockOnceOnAClick() async throws {
    let dock = DockProbe()
    let m = await model(try services(), dock: dock)
    #expect(!m.offersDockRefresh)
    await m.refreshDock()
    #expect(dock.count == 0)
    await m.submit()
    #expect(m.offersDockRefresh && m.canRefreshDock && m.dockButtonTitle == "Обновить Док")
    #expect(m.dockNote == "Док покажет новую иконку после перезапуска — это секунда, окна не закрываются")
    #expect(dock.count == 0)
    await m.refreshDock()
    #expect(dock.apps == [[URL(fileURLWithPath: "/tmp/root/Applications/Claude Work.app", isDirectory: true)]])
    #expect(m.dockRefresh == .refreshed)
    #expect(m.dockButtonTitle == "Док обновлён" && !m.canRefreshDock)
    await m.refreshDock()
    #expect(dock.count == 1)
  }

  /// The Dock is given the clone as saved (the fake edit keeps its app where it was).
  @Test func aSavedEditOffersTheDockRefreshToo() async throws {
    let dock = DockProbe()
    let m = await model(try services(), dock: dock)
    m.name = "Claude Job"
    await m.submit()
    #expect(m.offersDockRefresh && m.dockRefresh == .idle)
    await m.refreshDock()
    #expect(dock.apps.map { $0.map(\.path) } == [["/tmp/root/Applications/Claude Work.app"]])
  }

  @Test func aNewAppIsNotOfferedTheDockRefresh() async throws {
    let dock = DockProbe()
    let m = await model(try services(), mode: .add, dock: dock)
    m.name = "Claude mv2"
    await m.submit()
    guard case .done = m.phase else { Issue.record("expected done, got \(m.phase)"); return }
    #expect(!m.offersDockRefresh)
    await m.refreshDock()
    #expect(dock.count == 0)
  }

  @Test func aFailedDockRefreshSaysSoAndCanBeRetried() async throws {
    let dock = DockProbe(fails: true)
    let m = await model(try services(), dock: dock)
    await m.submit()
    await m.refreshDock()
    #expect(dock.count == 1 && m.dockRefresh == .failed)
    #expect(m.canRefreshDock && m.dockButtonTitle == "Обновить Док")
    #expect(m.dockNote == "Не удалось перезапустить Док — попробуйте ещё раз")
    await m.refreshDock()
    #expect(dock.count == 2)
  }

  // MARK: English

  @Test func theReinstallAndDockStringsInEnglish() async throws {
    try await Localization.$pinned.withValue("en") {
      let m = await model(try services())
      #expect(m.submitTitle == "Reinstall")
      #expect(m.note == "Rebuilds “Claude Work” from the current Claude, with a fresh icon. You stay signed in.")
      m.badge = "Wk"
      #expect(m.submitTitle == "Save")
      #expect(InstanceEditorText.reinstalling("Claude Work") == "Reinstalling “Claude Work”… usually 1–3 minutes")
      #expect(InstanceEditorText.reinstalled == "Reinstalled")
      #expect(InstanceEditorText.reinstallFailed == "Could not reinstall")
      #expect(InstanceEditorText.refreshDock == "Refresh Dock" && InstanceEditorText.dockRefreshed == "Dock refreshed")
      #expect(InstanceEditorText.dockRefreshNote
        == "The Dock shows the new icon after a restart — takes a second, no windows close")
      #expect(InstanceEditorText.dockRefreshFailed == "Could not restart the Dock — try again")
    }
  }
}
