import AppKit

/// Everything in the menu that can be highlighted and activated.
public enum AppMenuItem: Hashable, Sendable {
  case updateAll
  case tile(String)
  case add
  case release
  case login
  case quit
}

/// What a key press means in the menu. `activate` shows a tile's actions; `openApp` opens the tile's app directly.
public enum AppMenuKeyCommand: Equatable, Sendable {
  case up, down, left, right, next, previous, activate, openApp, close, quit

  /// Arrows, Tab / ⇧Tab, Return / Enter / Space, ⌥Return / ⌥Enter, Esc / ⌘W, ⌘Q; anything else is not the menu's.
  public init?(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
    let flags = modifiers.intersection([.command, .option, .control, .shift])
    if flags == .command {
      switch characters.lowercased() {
      case "q": self = .quit
      case "w": self = .close
      default: return nil
      }
      return
    }
    switch keyCode {
    case 126: self = .up
    case 125: self = .down
    case 123: self = .left
    case 124: self = .right
    case 48: self = flags.contains(.shift) ? .previous : .next
    case 36, 76: self = flags.contains(.option) ? .openApp : .activate
    case 49: self = .activate
    case 53: self = .close
    default: return nil
    }
  }
}

/// The order of the menu: banner button, the 3-column grid (tiles, then «Добавить»), the login switch, «Выйти», and
/// the release line last. The banner button is left out while an update runs (it is disabled then); a clone being
/// removed keeps its cell, so the grid keeps its shape.
public struct AppMenuLayout: Equatable, Sendable {
  public static let columns = 3

  public let grid: [AppMenuItem]
  public let linear: [AppMenuItem]
  /// Where the grid starts in `linear` (it is contiguous there).
  let gridStart: Int

  public init(content: AppMenuContent, hasRelease: Bool, busy: AppMenuBusy = .idle) {
    grid = content.tiles.map { .tile($0.slug) } + [.add]
    let head: [AppMenuItem] = content.banner == nil || busy.updating ? [] : [.updateAll]
    let rows: [AppMenuItem] = [.login, .quit] + (hasRelease ? [.release] : [])
    linear = head + grid + rows
    gridStart = head.count
  }
}

/// Moves the highlight the way a status-bar menu does: vertical arrows wrap, horizontal arrows only move inside the
/// grid, Tab cycles through everything.
public enum AppMenuNavigation {
  public static func target(
    from current: AppMenuItem?, _ command: AppMenuKeyCommand, in layout: AppMenuLayout
  ) -> AppMenuItem? {
    let linear = layout.linear
    guard let current, let index = linear.firstIndex(of: current) else {
      switch command {
      case .down, .right, .next: return linear.first
      case .up, .left, .previous: return linear.last
      case .activate, .openApp, .close, .quit: return current
      }
    }
    switch command {
    case .next: return linear[(index + 1) % linear.count]
    case .previous: return linear[(index - 1 + linear.count) % linear.count]
    case .activate, .openApp, .close, .quit: return current
    case .up, .down, .left, .right:
      if let cell = layout.grid.firstIndex(of: current) { return inGrid(cell, command, layout) }
      switch command {
      case .down: return linear[(index + 1) % linear.count]
      case .up: return linear[(index - 1 + linear.count) % linear.count]
      default: return current
      }
    }
  }

  private static func inGrid(_ cell: Int, _ command: AppMenuKeyCommand, _ layout: AppMenuLayout) -> AppMenuItem? {
    let grid = layout.grid
    let columns = AppMenuLayout.columns
    let linear = layout.linear
    switch command {
    case .left: return grid[max(cell - 1, 0)]
    case .right: return grid[min(cell + 1, grid.count - 1)]
    case .down:
      if cell + columns < grid.count { return grid[cell + columns] }
      if cell / columns < (grid.count - 1) / columns { return grid.last }
      return linear[(layout.gridStart + grid.count) % linear.count]
    case .up:
      if cell >= columns { return grid[cell - columns] }
      return layout.gridStart > 0 ? linear[layout.gridStart - 1] : linear.last
    default: return grid[cell]
    }
  }
}
