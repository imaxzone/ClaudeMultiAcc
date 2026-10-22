import Foundation

/// What the app is busy with that the menu shows: an update run (`UpdateFlow.isRunning`) and the clones being
/// removed (`DeleteFlow.deleting`). While `updating`, the banner button reads «Обновляется…» and every «Обновить»
/// is disabled; a clone in `deleting` is dimmed with a spinner and offers no actions.
public struct AppMenuBusy: Equatable, Sendable {
  public var updating: Bool
  /// Slugs of the clones being removed.
  public var deleting: Set<String>

  public init(updating: Bool = false, deleting: Set<String> = []) {
    self.updating = updating
    self.deleting = deleting
  }

  /// Nothing running.
  public static let idle = AppMenuBusy()

  public var isIdle: Bool { !updating && deleting.isEmpty }

  public func isDeleting(_ slug: String) -> Bool { deleting.contains(slug) }
}
