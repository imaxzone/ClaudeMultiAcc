import Foundation

/// The ClaudeMultiAcc.app this `cmacc` belongs to: the bundle it runs from (`<app>/Contents/Helpers/cmacc`), else
/// the installed copy — `/Applications` (where the disk image puts it), then `~/Applications`.
enum OwnApp {
  static let bundleName = "ClaudeMultiAcc.app"

  static func live(home: URL) -> URL {
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return url(executable: executable, home: home) { FileManager.default.fileExists(atPath: $0) }
  }

  static func url(executable: URL, home: URL, exists: (String) -> Bool) -> URL {
    let helpers = executable.deletingLastPathComponent()
    let contents = helpers.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    if helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", app.pathExtension == "app" {
      return app
    }
    let system = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(bundleName)
    if exists(system.path) { return system }
    return home.appendingPathComponent("Applications", isDirectory: true).appendingPathComponent(bundleName)
  }
}
