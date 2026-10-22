import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel that looks and behaves like a status-bar menu: menu material, rounded
/// corners, opens under the status item, takes the keyboard without activating the app.
final class AppMenuPanel: NSPanel {
  /// Key presses go here first; `true` means handled (so arrows, Tab and Space never reach SwiftUI focus).
  var keyHandler: ((NSEvent) -> Bool)?
  /// Right-clicks and Control-clicks go here first; `true` means handled (a tile's actions menu opened, so the
  /// click never reaches the tile underneath).
  var secondaryClickHandler: ((NSEvent) -> Bool)?
  /// ⌘W through the main menu (it sees key equivalents before the panel does) and «Закрыть» from it.
  var closeHandler: (() -> Void)?

  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .popUpMenu
    becomesKeyOnlyIfNeeded = false
    hidesOnDeactivate = false
    worksWhenModal = true
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    setAccessibilityLabel(AppMenuStrings.appName)
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, keyHandler?(event) == true { return }
    if Self.isSecondaryClick(event), secondaryClickHandler?(event) == true { return }
    super.sendEvent(event)
  }

  /// A right mouse down, or a left one with Control held (the context-menu click).
  static func isSecondaryClick(_ event: NSEvent) -> Bool {
    switch event.type {
    case .rightMouseDown: true
    case .leftMouseDown: event.modifierFlags.contains(.control)
    default: false
    }
  }

  /// The panel has no close button, so AppKit would beep: close the menu instead.
  override func performClose(_ sender: Any?) {
    closeHandler?()
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    item.action == #selector(performClose(_:)) || super.validateUserInterfaceItem(item)
  }

  /// Gap between the menu bar item and the panel, and the margin kept to the screen edges.
  static let gap: CGFloat = 4
  static let screenMargin: CGFloat = 6

  /// Left edge under the status item (moved left to stay on screen), top edge `gap` below it.
  static func frame(size: CGSize, below anchor: NSRect, visible: NSRect) -> NSRect {
    let maxX = visible.maxX - screenMargin - size.width
    let x = max(visible.minX + screenMargin, min(anchor.minX, maxX))
    let top = min(anchor.minY, visible.maxY) - gap
    return NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
  }
}

/// The menu material with a hairline edge, clipped to the menu's corner radius.
final class AppMenuMaterialView: NSVisualEffectView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    material = .menu
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = AppMenuStyle.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    updateBorder()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateBorder()
  }

  private func updateBorder() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.borderColor = AppMenuStyle.panelEdge.cgColor
    }
  }
}

/// Shows and hides the panel, sizes it to its SwiftUI content and closes it the way a menu closes: a click
/// anywhere else, Esc, another app activating, or the panel losing the keyboard.
@MainActor
final class AppMenuPanelController {
  let panel = AppMenuPanel()
  var onKey: ((AppMenuKeyCommand) -> Bool)?
  /// A right-click or Control-click at a point of the panel (window coordinates); `true` means it was handled.
  var onSecondaryClick: ((NSPoint) -> Bool)?
  var onDismiss: (() -> Void)?
  /// While a tile's actions menu is open, outside clicks and key loss belong to that menu.
  var isBusy: () -> Bool = { false }

  private let material = AppMenuMaterialView(frame: .zero)
  private let hosting: NSHostingController<AnyView>
  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var modelObservation: AnyCancellable?
  private weak var statusWindow: NSWindow?
  /// Bumped on every show, so a fade-out that finishes after a quick reopen leaves the panel alone.
  private var generation = 0

  init<V: View>(root: V, model: AppMenuModel) {
    let hosting = NSHostingController(rootView: AnyView(root))
    hosting.sizingOptions = []
    self.hosting = hosting
    material.addSubview(hosting.view)
    hosting.view.autoresizingMask = [.width, .height]
    panel.contentView = material
    panel.keyHandler = { [weak self] event in self?.handle(event) ?? false }
    panel.secondaryClickHandler = { [weak self] event in self?.onSecondaryClick?(event.locationInWindow) ?? false }
    panel.closeHandler = { [weak self] in _ = self?.onKey?(.close) }
    modelObservation = model.objectWillChange.sink { [weak self] _ in
      // objectWillChange fires before the new values land: measure on the next turn.
      DispatchQueue.main.async { self?.fitToContent() }
    }
  }

  /// Shown and not closing (a fading-out panel is already closed for the status item's toggle).
  private(set) var isVisible = false

  func show(below button: NSStatusBarButton) {
    statusWindow = button.window
    let anchor = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
    let screen = button.window?.screen ?? NSScreen.main
    let size = contentSize()
    panel.setFrame(
      AppMenuPanel.frame(size: size, below: anchor, visible: screen?.visibleFrame ?? anchor), display: false)
    hosting.view.frame = material.bounds
    generation += 1
    isVisible = true
    panel.alphaValue = 1
    panel.orderFrontRegardless()
    panel.makeKey()
    startMonitoring()
  }

  func close() {
    stopMonitoring()
    guard isVisible else { return }
    isVisible = false
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      panel.orderOut(nil)
      return
    }
    // Menus fade out quickly; opacity only.
    let closing = generation
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = AppMenuStyle.closeFade
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.generation == closing else { return }
        self.panel.orderOut(nil)
        self.panel.alphaValue = 1
      }
    })
  }

  private func contentSize() -> CGSize {
    CGSize(width: AppMenuStyle.width, height: AppMenuStyle.height(hosting))
  }

  /// Keeps the top edge in place while the content grows or shrinks.
  private func fitToContent() {
    guard isVisible else { return }
    let size = contentSize()
    let frame = panel.frame
    guard frame.size != size else { return }
    panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height),
                   display: true)
    panel.invalidateShadow()
  }

  private func handle(_ event: NSEvent) -> Bool {
    let command = AppMenuKeyCommand(
      keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags)
    guard let command else { return false }
    return onKey?(command) ?? false
  }

  private func startMonitoring() {
    stopMonitoring()
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    }) {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
      MainActor.assumeIsolated { self?.localClick(event) }
      return event
    }) {
      monitors.append(local)
    }
    let workspace = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(workspace.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let isSelf = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
      MainActor.assumeIsolated { if !isSelf { self?.dismiss() } }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.dismiss() }
    })
  }

  private func stopMonitoring() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    workspaceObservers = []
  }

  /// A click in another window of this app closes the menu; the status item's own click toggles it instead.
  private func localClick(_ event: NSEvent) {
    guard let window = event.window else { return dismiss() }
    if window === panel || window === statusWindow || window.parent === panel { return }
    dismiss()
  }

  private func dismiss() {
    guard isVisible, !isBusy() else { return }
    onDismiss?()
  }
}

/// The NSView behind each tile, so its actions menu opens anchored at the tile and a right-click finds its tile.
@MainActor
final class AppMenuAnchors {
  private final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }

  private var views: [String: WeakView] = [:]

  func register(_ view: NSView, for slug: String) {
    views[slug] = WeakView(view)
  }

  func view(for slug: String) -> NSView? {
    views[slug]?.view
  }

  /// The tile drawn at `point` (window coordinates) in `window`.
  func slug(at point: NSPoint, in window: NSWindow) -> String? {
    views.first { _, entry in
      guard let view = entry.view, view.window === window else { return false }
      return view.bounds.contains(view.convert(point, from: nil))
    }?.key
  }
}

struct TileAnchor: NSViewRepresentable {
  let slug: String
  let anchors: AppMenuAnchors?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    anchors?.register(view, for: slug)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    anchors?.register(view, for: slug)
  }
}

/// Opens a tile's actions menu.
@MainActor
protocol AppTileMenuPresenting: AnyObject {
  /// `completion` runs once the menu has closed (whether or not an item was chosen).
  func present(_ menu: NSMenu, forTile slug: String, completion: @escaping @MainActor () -> Void)
}

/// Pops the menu up centred under the tile, after the click that asked for it has finished.
@MainActor
final class AnchoredTileMenuPresenter: AppTileMenuPresenting {
  static let gap: CGFloat = 2
  private let anchors: AppMenuAnchors

  init(anchors: AppMenuAnchors) {
    self.anchors = anchors
  }

  func present(_ menu: NSMenu, forTile slug: String, completion: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { [anchors] in
      MainActor.assumeIsolated {
        defer { completion() }
        guard let view = anchors.view(for: slug), view.window != nil else { return }
        menu.popUp(positioning: nil, at: Self.origin(menuWidth: menu.size.width, in: view), in: view)
      }
    }
  }

  /// The menu's top-left corner in `view` coordinates: centred under the tile, moved sideways to stay inside the
  /// panel when it fits there.
  static func origin(menuWidth: CGFloat, in view: NSView) -> NSPoint {
    var x = (view.bounds.width - menuWidth) / 2
    if let content = view.window?.contentView {
      let panel = view.convert(content.bounds, from: content)
      x = clampedX(x, menuWidth: menuWidth, within: panel.minX...panel.maxX)
    }
    return NSPoint(x: x.rounded(), y: view.isFlipped ? view.bounds.maxY + gap : view.bounds.minY - gap)
  }

  /// `x` kept within `range` (inset by the panel padding), unless the menu is wider than that.
  static func clampedX(_ x: CGFloat, menuWidth: CGFloat, within range: ClosedRange<CGFloat>) -> CGFloat {
    let low = range.lowerBound + AppMenuStyle.padding
    let high = range.upperBound - AppMenuStyle.padding - menuWidth
    return low <= high ? min(max(x, low), high) : x
  }
}
