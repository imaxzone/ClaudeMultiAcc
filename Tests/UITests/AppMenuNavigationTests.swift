import AppKit
import Testing
@testable import UI

/// Keyboard model of the menu: arrows walk the 3-column grid and the rows, Tab cycles, Return/Space activate, ⌥Return
/// opens a tile's app.
@Suite struct AppMenuNavigationTests {
  /// ↻ + banner + main, 2nd, 5x, mv2 + «Добавить» (grid of 5: rows [main 2nd 5x] [mv2 add]) + login, quit, release.
  static let content = AppMenuContentTests.build()
  static let full = AppMenuLayout(content: content, hasRelease: true)
  static let plain = AppMenuLayout(
    content: AppMenuContentTests.build(versions: ["second": "3.1700.0", "mv2": "3.1700.0"]), hasRelease: false)

  static func go(_ from: AppMenuItem?, _ key: AppMenuKeyCommand, _ layout: AppMenuLayout = full) -> AppMenuItem? {
    AppMenuNavigation.target(from: from, key, in: layout)
  }

  /// ↻ at the top, the release line is the last row, under «Выйти».
  @Test func linearOrderIsHeaderBannerGridRowsRelease() {
    #expect(Self.full.linear == [
      .checkClaude, .updateAll, .tile("main"), .tile("second"), .tile("fivex"), .tile("mv2"), .add, .login, .quit,
      .release,
    ])
    #expect(Self.plain.linear.prefix(2) == [.checkClaude, .tile("main")])
    #expect(!Self.plain.linear.contains(.release))
    #expect(Self.full.grid == [.tile("main"), .tile("second"), .tile("fivex"), .tile("mv2"), .add])
  }

  @Test func nothingHighlightedStartsAtTheTopOrTheBottom() {
    #expect(Self.go(nil, .down) == .checkClaude)
    #expect(Self.go(nil, .right) == .checkClaude)
    #expect(Self.go(nil, .next) == .checkClaude)
    #expect(Self.go(nil, .up) == .release)
    #expect(Self.go(nil, .previous) == .release)
    #expect(Self.go(nil, .up, Self.plain) == .quit)
    #expect(Self.go(nil, .down, Self.plain) == .checkClaude)
    #expect(Self.go(.tile("gone"), .down) == .checkClaude)
    #expect(Self.go(nil, .openApp) == nil)
  }

  @Test func activatingKeepsTheHighlight() {
    for command in [AppMenuKeyCommand.activate, .openApp, .close, .quit] {
      #expect(Self.go(.tile("mv2"), command) == .tile("mv2"))
      #expect(Self.go(.login, command) == .login)
    }
  }

  @Test func arrowsWalkTheGridByColumnsAndRows() {
    #expect(Self.go(.tile("main"), .right) == .tile("second"))
    #expect(Self.go(.tile("fivex"), .right) == .tile("mv2"))
    #expect(Self.go(.add, .right) == .add)
    #expect(Self.go(.tile("main"), .left) == .tile("main"))
    #expect(Self.go(.tile("mv2"), .left) == .tile("fivex"))
    #expect(Self.go(.tile("main"), .down) == .tile("mv2"))
    #expect(Self.go(.tile("second"), .down) == .add)
    #expect(Self.go(.tile("fivex"), .down) == .add)
    #expect(Self.go(.tile("mv2"), .up) == .tile("main"))
    #expect(Self.go(.add, .up) == .tile("second"))
  }

  @Test func leavingTheGridGoesToTheBannerAndTheRows() {
    #expect(Self.go(.tile("second"), .up) == .updateAll)
    #expect(Self.go(.updateAll, .down) == .tile("main"))
    #expect(Self.go(.tile("mv2"), .down) == .login)
    #expect(Self.go(.add, .down) == .login)
    #expect(Self.go(.login, .up) == .add)
    #expect(Self.go(.login, .down) == .quit)
    #expect(Self.go(.quit, .up) == .login)
    #expect(Self.go(.quit, .down) == .release)
    #expect(Self.go(.release, .up) == .quit)
    #expect(Self.go(.tile("mv2"), .down, Self.plain) == .login)
    #expect(Self.go(.tile("main"), .up, Self.plain) == .checkClaude)
    #expect(Self.go(.checkClaude, .down, Self.plain) == .tile("main"))
  }

  @Test func verticalArrowsWrapLikeAMenu() {
    #expect(Self.go(.release, .down) == .checkClaude)
    #expect(Self.go(.checkClaude, .up) == .release)
    #expect(Self.go(.updateAll, .up) == .checkClaude)
    #expect(Self.go(.quit, .down, Self.plain) == .checkClaude)
  }

  @Test func horizontalArrowsDoNothingOutsideTheGrid() {
    for item in [AppMenuItem.checkClaude, .updateAll, .release, .login, .quit] {
      #expect(Self.go(item, .left) == item)
      #expect(Self.go(item, .right) == item)
    }
  }

  @Test func tabCyclesThroughEveryItem() throws {
    var item: AppMenuItem? = nil
    var visited: [AppMenuItem] = []
    for _ in Self.full.linear.indices {
      item = Self.go(item, .next)
      visited.append(try #require(item))
    }
    #expect(visited == Self.full.linear)
    #expect(Self.go(.release, .next) == .checkClaude)
    #expect(Self.go(.checkClaude, .previous) == .release)
    #expect(Self.go(.updateAll, .previous) == .checkClaude)
    #expect(Self.go(.add, .previous) == .tile("mv2"))
  }

  @Test func emptyGridStillReachesAddAndTheRows() {
    let layout = AppMenuLayout(content: .empty, hasRelease: false)
    #expect(layout.linear == [.checkClaude, .add, .login, .quit])
    #expect(Self.go(.add, .down, layout) == .login)
    #expect(Self.go(.add, .up, layout) == .checkClaude)
  }

  // MARK: Keys

  static func key(_ code: UInt16, _ characters: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> AppMenuKeyCommand? {
    AppMenuKeyCommand(keyCode: code, characters: characters, modifiers: modifiers)
  }

  @Test func keysMapToCommands() {
    #expect(Self.key(126) == .up)
    #expect(Self.key(125) == .down)
    #expect(Self.key(123) == .left)
    #expect(Self.key(124) == .right)
    #expect(Self.key(48, "\t") == .next)
    #expect(Self.key(48, "\t", .shift) == .previous)
    #expect(Self.key(36, "\r") == .activate)
    #expect(Self.key(76, "\u{3}") == .activate)
    #expect(Self.key(49, " ") == .activate)
    #expect(Self.key(36, "\r", .option) == .openApp)
    #expect(Self.key(76, "\u{3}", .option) == .openApp)
    #expect(Self.key(36, "\r", .shift) == .activate)
    #expect(Self.key(49, " ", .option) == .activate)
    #expect(Self.key(53, "\u{1b}") == .close)
    #expect(Self.key(12, "q", .command) == .quit)
    #expect(Self.key(13, "w", .command) == .close)
    #expect(Self.key(12, "q") == nil)
    #expect(Self.key(0, "a") == nil)
  }
}
