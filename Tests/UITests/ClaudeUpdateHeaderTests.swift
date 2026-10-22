import AppKit
import InstanceBuilder
import Support
import SwiftUI
import Testing
@testable import UI

/// The ↻ button and the status line at the top of the menu: what it says in every state and language, where it is in
/// the keyboard order, what a click does, how long a result stays, which Claude the banner offers, and the alert
/// after a failed manual check.
@MainActor
@Suite struct ClaudeUpdateHeaderTests {
  static let statuses: [ClaudeUpdateStatus] = [
    .idle, .checking, .downloading(version: "3.1623.3", percent: 42), .verifying(version: "3.1623.3"),
    .upToDate(version: "3.1623.3"), .ready(version: "3.1623.3"), .failed(.network("offline")),
  ]
  static let working: [ClaudeUpdateStatus] = statuses.filter(\.isWorking)
  static let failures: [ClaudeUpdateFailure] = [
    .officialMissing, .network("The request timed out."), .badAnswer("HTTP 500"),
    .untrustedURL("https://example.com/Claude.zip"), .notEnoughSpace(free: 1_200_000_000, needed: 2_000_000_000),
    .sizeMismatch(expected: 263_612_185, actual: 1_000), .checksumMismatch, .unpackFailed("ditto: error"),
    .notGenuine("team ABCDE12345"), .versionMismatch(expected: "3.1623.3", found: "3.1623.1"), .busy,
    .storage("read-only volume"),
  ]

  // MARK: Words

  @Test func everyStatusHasALineInBothLanguages() {
    Localization.$pinned.withValue("ru") {
      #expect(ClaudeUpdateText.line(.idle, current: "3.1623.0") == "Claude 3.1623.0")
      #expect(ClaudeUpdateText.line(.checking, current: "3.1623.0") == "Проверяю обновления Claude…")
      #expect(ClaudeUpdateText.line(.downloading(version: "3.1623.3", percent: 42), current: "3.1623.0")
        == "Скачиваю Claude 3.1623.3 — 42 %")
      #expect(ClaudeUpdateText.line(.verifying(version: "3.1623.3"), current: nil) == "Проверяю Claude 3.1623.3…")
      #expect(ClaudeUpdateText.line(.upToDate(version: "3.1623.3"), current: "3.1623.0")
        == "Обновлений Claude нет — у вас 3.1623.3")
      #expect(ClaudeUpdateText.line(.ready(version: "3.1623.3"), current: nil) == "Claude 3.1623.3 скачан")
      #expect(ClaudeUpdateText.line(.failed(.busy), current: "3.1623.0") == "Не удалось обновить Claude")
      #expect(ClaudeUpdateText.buttonLabel == "Проверить обновления Claude")
    }
    Localization.$pinned.withValue("en") {
      #expect(ClaudeUpdateText.line(.idle, current: "3.1623.0") == "Claude 3.1623.0")
      #expect(ClaudeUpdateText.line(.checking, current: nil) == "Checking for Claude updates…")
      #expect(ClaudeUpdateText.line(.downloading(version: "3.1623.3", percent: 42), current: nil)
        == "Downloading Claude 3.1623.3 — 42%")
      #expect(ClaudeUpdateText.line(.verifying(version: "3.1623.3"), current: nil) == "Verifying Claude 3.1623.3…")
      #expect(ClaudeUpdateText.line(.upToDate(version: "3.1623.3"), current: nil)
        == "No Claude updates — you have 3.1623.3")
      #expect(ClaudeUpdateText.line(.ready(version: "3.1623.3"), current: nil) == "Claude 3.1623.3 downloaded")
      #expect(ClaudeUpdateText.line(.failed(.checksumMismatch), current: nil) == "Couldn’t update Claude")
      #expect(ClaudeUpdateText.buttonLabel == "Check for Claude updates")
    }
    for language in Localization.languages {
      Localization.$pinned.withValue(language) {
        // Idle without a known Claude says nothing; everything else always has a line, never a bare key.
        #expect(ClaudeUpdateText.line(.idle, current: nil) == nil)
        #expect(ClaudeUpdateText.line(.idle, current: "") == nil)
        for status in Self.statuses {
          let line = ClaudeUpdateText.line(status, current: "3.1623.0")
          #expect(line?.isEmpty == false && line?.hasPrefix("claude.") == false, "\(language) \(status)")
        }
        // A percent outside 0…100 never shows as such.
        #expect(ClaudeUpdateText.line(.downloading(version: "3", percent: 140), current: nil)?.contains("100") == true)
        #expect(ClaudeUpdateText.line(.downloading(version: "3", percent: -5), current: nil)?.contains(" 0") == true)
      }
    }
  }

  @Test func everyFailureHasAnAlert() {
    for language in Localization.languages {
      Localization.$pinned.withValue(language) {
        let title = ClaudeUpdateText.failureAlert(.busy).title
        var messages: Set<String> = []
        for failure in Self.failures {
          let alert = ClaudeUpdateText.failureAlert(failure)
          #expect(alert.title == title, "\(language) \(failure)")
          #expect(alert.message.count > 20 && !alert.message.hasPrefix("claude."), "\(language) \(failure)")
          messages.insert(alert.message)
        }
        // A wrong size and a wrong checksum are the same news to the owner: the file is damaged.
        #expect(messages.count == Self.failures.count - 1, "\(language)")
      }
    }
    Localization.$pinned.withValue("ru") {
      let network = ClaudeUpdateText.failureAlert(.network("offline"))
      #expect(network.title == "Не удалось обновить Claude")
      #expect(network.message == "Нет связи с сервером обновлений Claude. Проверьте интернет и попробуйте позже.")
      #expect(ClaudeUpdateText.failureAlert(.notEnoughSpace(free: 1_200_000_000, needed: 2_000_000_000)).message
        == "Мало места на диске: нужно 2 ГБ, свободно 1,2 ГБ.")
      #expect(ClaudeUpdateText.failureAlert(.versionMismatch(expected: "3.1623.3", found: "3.1623.1")).message
        == "Скачан Claude 3.1623.1 вместо 3.1623.3 — он не будет использован.")
      #expect(ClaudeUpdateText.failureAlert(.officialMissing).message
        == "Claude не найден в «Программах». Установите его с claude.ai/download и попробуйте снова.")
      #expect(ClaudeUpdateText.failureAlert(.untrustedURL("x")).message
        == "Сервер предложил скачать Claude не с downloads.claude.ai — скачивание отменено.")
    }
    Localization.$pinned.withValue("en") {
      let network = ClaudeUpdateText.failureAlert(.network("offline"))
      #expect(network.title == "Couldn’t update Claude")
      #expect(network.message
        == "Can’t reach the Claude update server. Check your internet connection and try again later.")
      #expect(ClaudeUpdateText.failureAlert(.notEnoughSpace(free: 1_200_000_000, needed: 2_000_000_000)).message
        == "Not enough disk space: 2 GB needed, 1.2 GB free.")
      #expect(ClaudeUpdateText.failureAlert(.versionMismatch(expected: "3.1623.3", found: "3.1623.1")).message
        == "Downloaded Claude 3.1623.1 instead of 3.1623.3 — it won’t be used.")
    }
  }

  // MARK: Keyboard

  /// The header row is always there, so ↻ is always first; the banner button follows it, and the grid's top row goes
  /// up to whichever of the two is there.
  @Test func theHeaderIsFirstInKeyboardOrder() {
    let content = AppMenuContentTests.build()
    let full = AppMenuLayout(content: content, hasRelease: true)
    #expect(full.linear.prefix(3) == [.checkClaude, .updateAll, .tile("main")])
    #expect(full.linear.last == .release)
    let updating = AppMenuLayout(content: content, hasRelease: false, busy: AppMenuBusy(updating: true))
    #expect(updating.linear.prefix(2) == [.checkClaude, .tile("main")])
    #expect(AppMenuLayout(content: .empty, hasRelease: false).linear == [.checkClaude, .add, .login, .quit])

    func go(_ from: AppMenuItem?, _ key: AppMenuKeyCommand, _ layout: AppMenuLayout = full) -> AppMenuItem? {
      AppMenuNavigation.target(from: from, key, in: layout)
    }
    #expect(go(nil, .down) == .checkClaude)
    #expect(go(nil, .next) == .checkClaude)
    #expect(go(.checkClaude, .down) == .updateAll)
    #expect(go(.checkClaude, .up) == .release)
    #expect(go(.release, .down) == .checkClaude)
    #expect(go(.release, .next) == .checkClaude)
    #expect(go(.checkClaude, .left) == .checkClaude && go(.checkClaude, .right) == .checkClaude)
    #expect(go(.tile("second"), .up) == .updateAll)
    #expect(go(.tile("second"), .up, updating) == .checkClaude)
    #expect(go(.checkClaude, .down, updating) == .tile("main"))
  }

  // MARK: Clicking

  /// A click or Return on ↻ asks the app to check and leaves the menu open (and the highlight where it is); while a
  /// check runs both do nothing.
  @Test func checkingDoesNotCloseTheMenuAndIsIgnoredWhileWorking() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.prepareToOpen()
    controller.handle(.down)
    #expect(controller.model.highlight == AppMenuHighlight(item: .checkClaude, byKeyboard: true))
    controller.handle(.activate)
    #expect(fixture.actions.calls == ["checkClaude"])
    #expect(controller.model.highlight == AppMenuHighlight(item: .checkClaude, byKeyboard: true), "still open")

    for status in Self.working {
      fixture.claude.status = status
      controller.claudeUpdateChanged()
      #expect(controller.model.claudeUpdate == status)
      controller.handle(.activate)
      controller.activate(.checkClaude)
    }
    #expect(fixture.actions.calls == ["checkClaude"])
    #expect(controller.model.highlight?.item == .checkClaude)

    fixture.claude.status = .upToDate(version: "3.1700.0")
    controller.claudeUpdateChanged()
    controller.activate(.checkClaude)
    #expect(fixture.actions.calls == ["checkClaude", "checkClaude"])
    #expect(controller.model.highlight?.item == .checkClaude)
  }

  /// `claudeUpdateChanged()` reads only the status: no file reads, no other part of the model changes.
  @Test func aStatusChangeRereadsOnlyTheStatus() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    controller.prepareToOpen()
    let content = controller.model.content
    let requests = fixture.icons.requests.count
    fixture.claude.newest = "3.1800.0"
    fixture.claude.status = .downloading(version: "3.1800.0", percent: 7)
    controller.claudeUpdateChanged()
    #expect(controller.model.claudeUpdate == .downloading(version: "3.1800.0", percent: 7))
    #expect(controller.model.content == content)
    #expect(fixture.icons.requests.count == requests)
  }

  // MARK: How long a result stays

  /// «Обновлений нет», «скачан», «не удалось» stay while the panel is open (a list reload keeps them) and read as
  /// idle once it was closed and opened again; the next check shows its own result again.
  @Test func aTransientResultClearsAfterReopening() {
    let results: [ClaudeUpdateStatus] = [
      .upToDate(version: "3.1700.0"), .ready(version: "3.1800.0"), .failed(.network("offline")),
    ]
    for result in results {
      let fixture = AppMenuFixture()
      let controller = fixture.controller()
      controller.prepareToOpen()
      fixture.claude.status = .checking
      controller.claudeUpdateChanged()
      fixture.claude.status = result
      controller.claudeUpdateChanged()
      #expect(controller.model.claudeUpdate == result)
      controller.reload()
      #expect(controller.model.claudeUpdate == result, "a reload while open keeps it")
      controller.close()
      controller.prepareToOpen()
      #expect(controller.model.claudeUpdate == .idle, "\(result)")
      controller.reload()
      #expect(controller.model.claudeUpdate == .idle)

      fixture.claude.status = .checking
      controller.claudeUpdateChanged()
      #expect(controller.model.claudeUpdate == .checking)
      fixture.claude.status = result
      controller.claudeUpdateChanged()
      #expect(controller.model.claudeUpdate == result, "a new check shows its result")
    }
  }

  /// A result that arrives while the menu is closed (an automatic download, a check the owner closed the menu on) is
  /// shown at the next open, once.
  @Test func aResultThatArrivedWhileClosedIsShownOnce() {
    let fixture = AppMenuFixture()
    let controller = fixture.controller()
    fixture.claude.status = .ready(version: "3.1800.0")
    controller.claudeUpdateChanged()
    controller.prepareToOpen()
    #expect(controller.model.claudeUpdate == .ready(version: "3.1800.0"))
    controller.close()
    controller.prepareToOpen()
    #expect(controller.model.claudeUpdate == .idle)
  }

  // MARK: The banner

  @Test(.russian) func theBannerTargetsTheNewestClaude() {
    var fixture = AppMenuFixture()
    let old = "3.1623.0"
    fixture.installed = FakeVersions(byPath: Dictionary(
      uniqueKeysWithValues: AppMenuContentTests.instances.compactMap { $0.appPath.map { ($0, old) } }))
    fixture.claude.newest = "3.1623.3"
    let controller = fixture.controller()
    controller.prepareToOpen()
    #expect(controller.model.content.banner?.version == "3.1623.3")
    #expect(controller.model.content.banner?.slugs == ["second", "fivex", "mv2"])
    #expect(controller.model.content.tiles.first { $0.slug == "mv2" }?.updateTo == "3.1623.3")
    #expect(controller.model.content.tiles.first { $0.slug == "main" }?.updateTo == nil)
    #expect(controller.model.claudeVersion == "3.1623.3")

    // Nothing downloaded: the official app is the target, as before.
    fixture.claude.newest = nil
    controller.reload()
    #expect(controller.model.content.banner == nil)
    #expect(controller.model.claudeVersion == old)
  }

  // MARK: The view and the app

  /// The header keeps one height whatever it says (the panel never jumps), and fits the menu's width in both
  /// languages, with the longest version a feed may send.
  @Test func theHeaderKeepsItsHeightAndFitsTheMenu() {
    let inner = AppMenuStyle.width - 2 * AppMenuStyle.padding
    let long = "123456.123456.123456.123456"
    var heights: Set<CGFloat> = []
    for language in Localization.languages {
      Localization.$pinned.withValue(language) {
        for status in Self.statuses + [.downloading(version: long, percent: 100), .upToDate(version: long)] {
          for version in [nil, "3.1623.0"] {
            let view = ClaudeUpdateHeaderView(
              status: status, version: version, isHighlighted: false, hasFocusRing: false, onCheck: {},
              onHover: { _ in })
            let size = NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: inner, height: 1000))
            #expect(size.width <= inner, "\(language) \(status): \(size.width)")
            heights.insert(size.height)
          }
        }
      }
    }
    #expect(heights.count == 1, "\(heights)")
  }

  /// ↻ turns only while a check runs; with Reduce Motion it stays still and dimmed instead.
  @Test func reduceMotionKeepsTheButtonStill() {
    #expect(CheckClaudeSymbol.spins(isWorking: true, reduceMotion: false))
    #expect(!CheckClaudeSymbol.spins(isWorking: true, reduceMotion: true))
    #expect(!CheckClaudeSymbol.spins(isWorking: false, reduceMotion: false))
    #expect(CheckClaudeSymbol.opacity(isWorking: true, reduceMotion: true) < 1)
    #expect(CheckClaudeSymbol.opacity(isWorking: true, reduceMotion: false) == 1)
    #expect(CheckClaudeSymbol.opacity(isWorking: false, reduceMotion: true) == 1)
  }

  @Test func theAppsActionRunsTheCheck() throws {
    final class Counter {
      var checks = 0
    }
    let counter = Counter()
    let root = try makeTempDir()
    let services = UpdateFlowServices(
      ensureSigning: {}, applyPending: { [] }, loadInstances: { [] },
      restart: { CloneRestartReport(updated: $0, problems: []) })
    let flow = UpdateFlow(
      services: services, settings: SettingsStore(file: root.appendingPathComponent("settings.json")),
      dialogs: AlertUpdateDialogs()) {}
    let actions = AppActions(
      list: InstanceList(paths: Paths(home: root)), updates: flow,
      editor: InstanceEditorWindowController { _ in fatalError("never shown") }, remove: { _ in },
      checkClaude: { counter.checks += 1 })
    actions.checkClaudeUpdates()
    #expect(counter.checks == 1)
  }
}
