import AppKit
import IconRenderer
import Support
import SwiftUI
import Testing
@testable import UI

/// The AppKit pieces: the tile actions menu, the panel's geometry and keys, tile icons, the status glyph.
@MainActor
@Suite(.russian) struct AppMenuPartsTests {
  static let tiles = AppMenuContentTests.build().tiles

  static func tile(_ slug: String) -> AppTile {
    tiles.first { $0.slug == slug } ?? tiles[0]
  }

  // MARK: Tile actions menu

  @Test func tileMenuSectionsFollowTheDesign() {
    let titles = { (slug: String) in AppTileMenu.sections(for: Self.tile(slug)).map { $0.map(\.title) } }
    #expect(titles("mv2") == [
      ["Открыть", "Обновить до 3.1700.0", "Изменить…", "Переустановить…", "Показать в Finder"],
      ["Удалить «Claude mv2»…"],
    ])
    #expect(titles("fivex") == [
      ["Открыть", "Изменить…", "Переустановить…", "Показать в Finder"], ["Удалить «Claude 5x акк»…"],
    ])
    #expect(titles("main") == [["Открыть", "Показать в Finder"]])
    #expect(Self.tiles.allSatisfy { AppTileMenu.sections(for: $0).first?.first?.command == .open })
    let all = Self.tiles.flatMap { AppTileMenu.sections(for: $0).joined() }
    #expect(all.filter(\.isDestructive).allSatisfy { $0.command == .delete })
    #expect(AppTileCommand.allCases.first == .open)
  }

  @Test func nsMenuHasSymbolsARedDeleteAndTheTarget() throws {
    var chosen: [AppTileCommand] = []
    let target = AppTileMenuTarget { chosen.append($0) }
    let menu = AppTileMenu.make(for: Self.tile("mv2"), target: target)
    #expect(menu.items.count == 7)
    #expect(menu.items[5].isSeparatorItem)
    #expect(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil && $0.target === target })
    #expect(!menu.autoenablesItems)
    let delete = try #require(menu.items.last)
    let color = delete.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    #expect(color == .systemRed)
    #expect(menu.items[0].attributedTitle == nil)
    menu.performActionForItem(at: 6)
    menu.performActionForItem(at: 0)
    menu.performActionForItem(at: 3)
    #expect(chosen == [.delete, .open, .reinstall])
  }

  /// Window coordinates (bottom-up) of the panel to the tile drawn there; another window's point is none.
  @Test func anchorsFindTheTileUnderAPoint() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
                          backing: .buffered, defer: true)
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    window.contentView = content
    let first = FlippedView(frame: NSRect(x: 10, y: 10, width: 92, height: 90))
    let second = FlippedView(frame: NSRect(x: 104, y: 10, width: 92, height: 90))
    content.addSubview(first)
    content.addSubview(second)
    let anchors = AppMenuAnchors()
    anchors.register(first, for: "main")
    anchors.register(second, for: "second")
    // The flipped content's y 10…100 is the window's y 100…190.
    #expect(anchors.slug(at: NSPoint(x: 50, y: 150), in: window) == "main")
    #expect(anchors.slug(at: NSPoint(x: 150, y: 120), in: window) == "second")
    #expect(anchors.slug(at: NSPoint(x: 250, y: 150), in: window) == nil)
    #expect(anchors.slug(at: NSPoint(x: 50, y: 50), in: window) == nil)
    let other = NSWindow(contentRect: window.frame, styleMask: .borderless, backing: .buffered, defer: true)
    #expect(anchors.slug(at: NSPoint(x: 50, y: 150), in: other) == nil)
  }

  @Test func menuOpensCentredUnderTheTileInsideThePanel() {
    let flipped = FlippedView(frame: NSRect(x: 0, y: 0, width: 92, height: 90))
    #expect(AnchoredTileMenuPresenter.origin(menuWidth: 200, in: flipped) == NSPoint(x: -54, y: 92))
    let plain = NSView(frame: NSRect(x: 0, y: 0, width: 92, height: 90))
    #expect(AnchoredTileMenuPresenter.origin(menuWidth: 60, in: plain) == NSPoint(x: 16, y: -2))

    // In a 300 pt panel: the first column's menu moves right to the panel's padding, the last one's left.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .borderless,
                          backing: .buffered, defer: true)
    let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    window.contentView = content
    let first = FlippedView(frame: NSRect(x: 10, y: 10, width: 92, height: 90))
    let last = FlippedView(frame: NSRect(x: 198, y: 10, width: 92, height: 90))
    content.addSubview(first)
    content.addSubview(last)
    #expect(AnchoredTileMenuPresenter.origin(menuWidth: 200, in: first).x == -4)
    #expect(AnchoredTileMenuPresenter.origin(menuWidth: 200, in: last).x == -104)
    #expect(AnchoredTileMenuPresenter.origin(menuWidth: 400, in: first).x == -154, "wider than the panel: centred")
  }

  /// A real pop-up from an anchor in the panel actually opens (a manual harness: it shows a menu on screen briefly).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CMACC_LIVE_MENU"] == "1"))
  func liveTileMenuReallyOpens() async throws {
    let anchors = AppMenuAnchors()
    let panel = AppMenuPanel()
    panel.setFrame(NSRect(x: 200, y: 400, width: 300, height: 200), display: false)
    let anchor = NSView(frame: NSRect(x: 10, y: 10, width: 92, height: 90))
    panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    panel.contentView?.addSubview(anchor)
    anchors.register(anchor, for: "mv2")
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    let watcher = MenuOpenWatcher()
    let menu = AppTileMenu.make(for: Self.tile("mv2"), target: AppTileMenuTarget { _ in })
    menu.delegate = watcher
    var closed = false
    AnchoredTileMenuPresenter(anchors: anchors).present(menu, forTile: "mv2") { closed = true }
    for _ in 0..<200 where !closed { try await Task.sleep(for: .milliseconds(20)) }
    #expect(watcher.opened)
    #expect(closed)
  }

  /// The real panel under a real status item (a manual harness: it shows on screen for a moment). Writes a
  /// screen capture of the panel to `$CMACC_LIVE_MENU_SHOT` when set.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CMACC_LIVE_MENU"] == "1"))
  func livePanelOpensUnderTheStatusItemAndTakesTheKeyboard() async throws {
    let fixture = AppMenuFixture()
    let menu = fixture.controller()
    let status = StatusItemController(menu: menu)
    defer { status.remove() }
    let button = try #require(status.statusItem.button)
    for _ in 0..<50 where button.window == nil { try await Task.sleep(for: .milliseconds(20)) }
    menu.open(relativeTo: button)
    #expect(menu.isOpen)
    let panel = try #require(NSApp.windows.compactMap { $0 as? AppMenuPanel }.first { $0.isVisible })
    try await Task.sleep(for: .milliseconds(300))
    let item = try #require(button.window).frame
    #expect(panel.frame.maxY <= item.minY)
    #expect(panel.frame.width == AppMenuStyle.width)
    #expect(panel.isKeyWindow, "the non-activating panel takes the keyboard")
    if let shot = ProcessInfo.processInfo.environment["CMACC_LIVE_MENU_SHOT"] {
      let capture = Process()
      capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      capture.arguments = ["-x", "-o", "-l\(panel.windowNumber)", shot]
      try capture.run()
      capture.waitUntilExit()
    }
    let down = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
      characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
    // Delivered the way the window server hands it to the key window (posting it would need a running NSApp).
    panel.sendEvent(down)
    #expect(menu.model.highlight == AppMenuHighlight(item: .updateAll, byKeyboard: true))
    #expect(menu.handle(.close))
    #expect(!menu.isOpen)
  }

  // MARK: Panel

  @Test func panelOpensUnderTheItemAndStaysOnScreen() {
    let visible = NSRect(x: 0, y: 0, width: 1512, height: 944)
    let size = CGSize(width: 300, height: 260)
    let item = NSRect(x: 1000, y: 944, width: 30, height: 24)
    #expect(AppMenuPanel.frame(size: size, below: item, visible: visible) == NSRect(x: 1000, y: 680, width: 300, height: 260))
    let nearEdge = NSRect(x: 1400, y: 944, width: 30, height: 24)
    #expect(AppMenuPanel.frame(size: size, below: nearEdge, visible: visible).maxX == 1506)
    let left = NSRect(x: -20, y: 944, width: 30, height: 24)
    #expect(AppMenuPanel.frame(size: size, below: left, visible: visible).minX == 6)
  }

  @Test func panelTakesTheKeyboardWithoutActivatingTheApp() {
    let panel = AppMenuPanel()
    #expect(panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.level == .popUpMenu)
    #expect(!panel.hidesOnDeactivate)
  }

  @Test func panelRoutesMenuKeysAndLetsOthersThrough() throws {
    let controller = AppMenuPanelController(root: EmptyView(), model: AppMenuModel())
    var commands: [AppMenuKeyCommand] = []
    controller.onKey = { commands.append($0); return true }
    let panel = controller.panel
    func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    panel.sendEvent(try key(125, "\u{F701}"))
    panel.sendEvent(try key(48, "\t", .shift))
    panel.sendEvent(try key(49, " "))
    panel.sendEvent(try key(36, "\r", .option))
    panel.sendEvent(try key(53, "\u{1b}"))
    panel.sendEvent(try key(12, "q", .command))
    panel.sendEvent(try key(0, "a"))
    #expect(commands == [.down, .previous, .activate, .openApp, .close, .quit])
  }

  /// Right-clicks and Control-clicks reach the controller (window coordinates) before the tile sees them.
  @Test func panelRoutesRightAndControlClicks() throws {
    let controller = AppMenuPanelController(root: EmptyView(), model: AppMenuModel())
    var points: [NSPoint] = []
    controller.onSecondaryClick = { points.append($0); return true }
    let panel = controller.panel
    func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = [], at point: NSPoint = .zero) throws
      -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    panel.sendEvent(try mouse(.rightMouseDown, at: NSPoint(x: 10, y: 20)))
    panel.sendEvent(try mouse(.leftMouseDown, .control, at: NSPoint(x: 30, y: 40)))
    #expect(points == [NSPoint(x: 10, y: 20), NSPoint(x: 30, y: 40)])
    #expect(AppMenuPanel.isSecondaryClick(try mouse(.rightMouseDown)))
    #expect(AppMenuPanel.isSecondaryClick(try mouse(.leftMouseDown, .control)))
    #expect(!AppMenuPanel.isSecondaryClick(try mouse(.leftMouseDown)))
    #expect(!AppMenuPanel.isSecondaryClick(try mouse(.leftMouseDown, .option)))
    #expect(!AppMenuPanel.isSecondaryClick(try mouse(.leftMouseUp, .control)))
    #expect(!AppMenuPanel.isSecondaryClick(try mouse(.rightMouseUp)))
  }

  // MARK: Icons

  @Test func cloneIconComesFromItsOwnIcnsFile() async throws {
    let app = try makeTempDir().appendingPathComponent("Claude mv2.app", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIconFile": "electron"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    #expect(BundleIconLoader.icnsURL(appPath: app.path) == nil, "no file yet")
    try await Self.writeIcns(to: resources.appendingPathComponent("electron.icns"))
    #expect(BundleIconLoader.icnsURL(appPath: app.path)?.lastPathComponent == "electron.icns")

    let loader = BundleIconLoader()
    let icon = try #require(loader.icon(for: .bundleIcns(appPath: app.path)))
    #expect(icon.size.width > 0)
    #expect(loader.icon(for: .bundleIcns(appPath: app.path)) === icon, "cached while the file is unchanged")
    #expect(loader.icon(for: .bundleIcns(appPath: app.appendingPathComponent("missing.app").path)) == nil)
    #expect(loader.icon(for: AppTileIconSource.none) == nil)
  }

  @Test func iconFileNameIsConfinedToResources() async throws {
    let app = try makeTempDir().appendingPathComponent("X.app", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIconFile": "../../evil.icns"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    try await Self.writeIcns(to: resources.appendingPathComponent("evil.icns"))
    #expect(BundleIconLoader.icnsURL(appPath: app.path)?.deletingLastPathComponent().lastPathComponent == "Resources")
  }

  /// A real `.icns` (via `iconutil`) of the demo icon.
  static func writeIcns(to url: URL) async throws {
    var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let cg = try #require(DemoIcon.image(badge: "mv2").cgImage(forProposedRect: &rect, context: nil, hints: nil))
    try await IcnsTool(runner: SystemProcessRunner()).writeIcns(from: cg, to: url, workDir: try makeTempDir())
  }

  // MARK: Status glyph

  /// Alpha summed over the dot's gap, from the glyph drawn at 2×.
  static func inkInDotGap(_ image: NSImage) throws -> Int {
    let scale: CGFloat = 2
    let pixels = Int(StatusGlyph.size.width * scale)
    let rep = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = StatusGlyph.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: StatusGlyph.size))
    NSGraphicsContext.restoreGraphicsState()
    let radius = StatusGlyph.dotDiameter / 2 + 1
    var ink = 0
    for y in 0..<pixels {
      for x in 0..<pixels {
        let point = CGPoint(x: (CGFloat(x) + 0.5) / scale, y: StatusGlyph.size.height - (CGFloat(y) + 0.5) / scale)
        guard hypot(point.x - StatusGlyph.dotCenter.x, point.y - StatusGlyph.dotCenter.y) <= radius else { continue }
        ink += rep.colorAt(x: x, y: y).map { Int($0.alphaComponent * 255) } ?? 0
      }
    }
    return ink
  }

  @Test func statusGlyphIsATemplateWithAGapForTheDot() throws {
    let plain = StatusGlyph.image(cutout: false)
    let gapped = StatusGlyph.image(cutout: true)
    #expect(plain.isTemplate && gapped.isTemplate)
    #expect(plain.size == CGSize(width: 18, height: 18))
    #expect(try Self.inkInDotGap(plain) > 0)
    #expect(try Self.inkInDotGap(gapped) == 0)
  }
}

final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// Records that a menu opened and closes it right away.
@MainActor
final class MenuOpenWatcher: NSObject, NSMenuDelegate {
  private(set) var opened = false

  func menuWillOpen(_ menu: NSMenu) {
    opened = true
    // Runs on the main run loop, where the menu lives.
    nonisolated(unsafe) let menu = menu
    RunLoop.main.perform(inModes: [.eventTracking, .default]) { menu.cancelTracking() }
  }
}
