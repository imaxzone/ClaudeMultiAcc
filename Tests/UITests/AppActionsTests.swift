import AppKit
import InstanceBuilder
import Support
import Synchronization
import Testing
@testable import UI

/// «Открыть» in the live app: the instance's own app, launched or brought to the front; anything that stands in the
/// way is only logged.
@MainActor
@Suite struct AppActionsTests {
  /// Records the apps it is asked to open; refuses them when told to.
  final class RecordingOpener: AppOpening {
    struct Refused: Error {}

    let opened = Mutex<[String]>([])
    let refuses: Bool

    init(refuses: Bool = false) {
      self.refuses = refuses
    }

    func open(app: URL) async throws {
      opened.withLock { $0.append(app.path) }
      if refuses { throw Refused() }
    }

    var paths: [String] { opened.withLock { $0 } }
  }

  static let instances = AppMenuContentTests.instances

  @Test func openLaunchesTheClonesOwnApp() async throws {
    let opener = RecordingOpener()
    let task = try #require(AppActions.openApp(slug: "mv2", in: Self.instances, opener: opener))
    await task.value
    #expect(opener.paths == ["/Applications/Claude mv2.app"])
  }

  @Test func openLaunchesTheOfficialAppToo() async throws {
    let opener = RecordingOpener()
    await AppActions.openApp(slug: "main", in: Self.instances, opener: opener)?.value
    #expect(opener.paths == ["/Applications/Claude.app"])
  }

  /// A slug that is gone, a CLI-only account or an empty path: nothing to open, nothing shown.
  @Test func nothingToOpenOpensNothing() {
    let opener = RecordingOpener()
    let empty = AppMenuContentTests.app("empty", "Claude empty", path: "")
    #expect(AppActions.openApp(slug: "gone", in: Self.instances, opener: opener) == nil)
    #expect(AppActions.openApp(slug: "alt", in: Self.instances, opener: opener) == nil)
    #expect(AppActions.openApp(slug: "empty", in: [empty], opener: opener) == nil)
    #expect(opener.paths.isEmpty)
  }

  @Test func aRefusedLaunchIsOnlyLogged() async throws {
    let opener = RecordingOpener(refuses: true)
    let task = try #require(AppActions.openApp(slug: "second", in: Self.instances, opener: opener))
    await task.value
    #expect(opener.paths == ["/Applications/Claude 2nd.app"])
  }
}

/// The new actions in both languages.
@MainActor
@Suite struct AppTileActionStringsTests {
  @Test(.english) func actionsInEnglish() {
    #expect(AppMenuStrings.open == "Open")
    #expect(AppMenuStrings.reinstall == "Reinstall…")
    #expect(AppMenuStrings.tileHint == "Shows actions")
    let titles = AppMenuPartsTests.tiles.map { AppTileMenu.sections(for: $0).joined().map(\.title) }
    #expect(titles.first == ["Open", "Show in Finder"])
    #expect(titles.last == ["Open", "Update to 3.1700.0", "Edit…", "Reinstall…", "Show in Finder", "Delete “Claude mv2”…"])
  }

  @Test(.russian) func actionsInRussian() {
    #expect(AppMenuStrings.open == "Открыть")
    #expect(AppMenuStrings.reinstall == "Переустановить…")
    #expect(AppMenuStrings.tileHint == "Показывает действия")
  }
}
