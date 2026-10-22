import AppKit
import Combine
import Support

/// What the status item shows in the glyph's gap.
enum StatusItemIndicator: Equatable {
  case none
  /// A clone is behind.
  case dot
  /// An update runs.
  case spinner
}

/// Owns the menu-bar status item: the template glyph, the blue dot while a clone is behind (a tiny spinner while an
/// update runs), and the app menu (`AppMenuController`) that a click opens and closes.
@MainActor
public final class StatusItemController: NSObject {
  let statusItem: NSStatusItem
  let menu: AppMenuController
  let dot = StatusDotView(frame: NSRect(origin: .zero, size: CGSize(width: StatusDotView.side,
                                                                         height: StatusDotView.side)))
  private let statusBar: NSStatusBar
  private var observation: AnyCancellable?
  private var rendered: StatusItemIndicator?

  public init(menu: AppMenuController, statusBar: NSStatusBar = .system) {
    self.menu = menu
    self.statusBar = statusBar
    statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
    super.init()
    if let button = statusItem.button {
      button.target = self
      button.action = #selector(buttonPressed(_:))
      // Like a menu: open on mouse down, either button.
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
      button.imagePosition = .imageOnly
      attachDot(to: button)
    }
    menu.onVisibilityChange = { [weak self] isOpen in self?.setHighlighted(isOpen) }
    // `@Published` publishes before the value lands: read the model on the next main-actor turn.
    let model = menu.model
    observation = model.$content.map { _ in () }
      .merge(with: model.$busy.map { _ in () }, model.$release.map { _ in () })
      .sink { [weak self] _ in
        Task { @MainActor in self?.updateButton() }
      }
    menu.reload()
    updateButton()
  }

  /// Removes the item from the menu bar.
  public func remove() {
    observation = nil
    menu.close()
    statusBar.removeStatusItem(statusItem)
  }

  func updateButton() {
    guard let button = statusItem.button else { return }
    let model = menu.model
    let indicator = Self.indicator(hasUpdates: model.content.hasUpdates, busy: model.busy)
    if indicator != rendered {
      button.image = StatusGlyph.image(cutout: indicator != .none)
      dot.isHidden = indicator == .none
      if indicator != .none { dot.mode = indicator == .spinner ? .spinner : .dot }
      rendered = indicator
    }
    let label = Self.accessibilityLabel(content: model.content, busy: model.busy, release: model.release)
    button.setAccessibilityLabel(label)
    button.toolTip = label
  }

  /// The spinner while an update runs (even once no clone is behind, e.g. during the restart question), the dot
  /// while a clone is behind. Removing a clone leaves the glyph alone; the label says it.
  static func indicator(hasUpdates: Bool, busy: AppMenuBusy) -> StatusItemIndicator {
    if busy.updating { return .spinner }
    return hasUpdates ? .dot : .none
  }

  /// «ClaudeMultiAcc», or what is going on: «ClaudeMultiAcc — есть версия 3.1700.0 для 2nd и mv2; удаляется
  /// «Claude 5x акк»; новая версия ClaudeMultiAcc 1.4.0». A running update replaces the «есть версия» part.
  static func accessibilityLabel(content: AppMenuContent, busy: AppMenuBusy, release: AppReleaseInfo?) -> String {
    var parts: [String] = []
    if busy.updating {
      parts.append(AppMenuStrings.statusUpdating)
    } else if let banner = content.banner {
      parts.append(AppMenuStrings.statusUpdateAvailable(version: banner.version, names: banner.shortNames))
    }
    if !busy.deleting.isEmpty {
      // In grid order; a slug without a tile (already gone from the list) by its slug.
      let known = content.tiles.filter { busy.isDeleting($0.slug) }
      let unknown = busy.deleting.subtracting(known.map(\.slug)).sorted()
      parts.append(AppMenuStrings.statusDeleting(names: known.map(\.name) + unknown))
    }
    if let release {
      parts.append(AppMenuStrings.statusRelease(version: release.version))
    }
    return AppMenuStrings.statusItem(parts: parts)
  }

  @objc private func buttonPressed(_ sender: NSStatusBarButton) {
    menu.toggle(relativeTo: sender)
  }

  private func setHighlighted(_ isOpen: Bool) {
    guard let button = statusItem.button else { return }
    // After the click's own tracking has reset the highlight.
    DispatchQueue.main.async { button.highlight(isOpen) }
  }

  /// The dot keeps its place relative to the centred glyph whatever the menu bar's height.
  private func attachDot(to button: NSStatusBarButton) {
    dot.translatesAutoresizingMaskIntoConstraints = false
    dot.isHidden = true
    button.addSubview(dot)
    let offset = CGPoint(
      x: StatusGlyph.dotCenter.x - StatusGlyph.size.width / 2, y: StatusGlyph.dotCenter.y - StatusGlyph.size.height / 2)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: StatusDotView.side),
      dot.heightAnchor.constraint(equalToConstant: StatusDotView.side),
      dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: offset.x),
      // Layout anchors run top-down: the dot is above the centre.
      dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -offset.y),
    ])
  }
}
