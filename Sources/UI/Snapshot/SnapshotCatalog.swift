import AppKit

/// Every surface of the review (`cmacc ui snapshot`): the new menu and its status item (`AppMenuShots`), rendered
/// offscreen from `AppMenuDemo` in each appearance. File names: `<surface>-<light|dark>.png`; the status item as
/// `statusitem[-update]-<appearance>@1x/@2x`.
@MainActor
public enum SnapshotCatalog {
  /// The menu-bar strip around the status item, in points.
  public static let menuBarStrip = CGSize(width: 104, height: 24)

  /// One output file: its name for an appearance suffix, and how to draw it.
  struct Shot {
    let name: (String) -> String
    let render: (NSAppearance.Name) throws -> Data
  }

  /// Renders every shot for every appearance into `dir` and returns the written files in order.
  public static func renderAll(to dir: URL, appearances: [NSAppearance.Name], scale: CGFloat) async throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try appearances.flatMap { appearance in
      try AppMenuShots.all(scale: scale).map { shot in
        let url = dir.appendingPathComponent(shot.name(suffix(appearance)))
        try shot.render(appearance).write(to: url)
        return url
      }
    }
  }

  static func suffix(_ appearance: NSAppearance.Name) -> String {
    switch appearance {
    case .aqua: "light"
    case .darkAqua: "dark"
    default: appearance.rawValue
    }
  }
}
