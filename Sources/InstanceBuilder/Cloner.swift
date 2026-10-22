import Foundation
import Support

/// Steps 3 and 5: APFS clone copy of the source (`cp -Rc`, read-only on the source) and bundle hygiene.
public struct Cloner: Sendable {
  static let leftovers = ["Icon\r", "Contents/embedded.provisionprofile", "Contents/CodeResources"]
  private let runner: ProcessRunning

  public init(runner: ProcessRunning) {
    self.runner = runner
  }

  public func copy(source: URL, to destination: URL) async throws {
    try await runner.runChecked(BuilderTool.cp, ["-Rc", source.path, destination.path], timeout: BuilderTool.copyTimeout)
  }

  /// Clears extended attributes and removes Finder's `Icon\r`, the provisioning profile and the stapled
  /// notarization ticket (`Contents/CodeResources`), none of which fit a re-signed clone. Returns a detail line.
  public func clean(app: URL) async throws -> String {
    try await runner.runChecked(BuilderTool.xattr, ["-cr", app.path], timeout: BuilderTool.copyTimeout)
    var removed: [String] = []
    for path in Self.leftovers {
      let url = app.appendingPathComponent(path)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      try FileManager.default.removeItem(at: url)
      removed.append(path == "Icon\r" ? "Icon\\r" : path)
    }
    return removed.isEmpty ? "xattrs cleared" : "xattrs cleared; removed \(removed.joined(separator: ", "))"
  }
}
