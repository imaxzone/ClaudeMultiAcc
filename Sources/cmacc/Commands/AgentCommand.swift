import Foundation
import InstanceBuilder
import Support

/// `cmacc agent print|install --kind update-watcher [--yes]`. `install` only writes the plist after a
/// confirmation and prints the `launchctl bootstrap` command for the user; it never loads anything itself.
/// `--kind app` is retired: launch at login is the menu switch now, so it only says so and does nothing.
struct AgentCommand: Command {
  static let name = "agent"
  static let summary = "LaunchAgents: agent print|install --kind update-watcher [--yes]"
  static let usageText = "Usage: cmacc agent print|install --kind update-watcher [--app <path>] [--yes]"
  static let retiredAppNotice = """
    Launch at login is now the “Open at Login” switch in the ClaudeMultiAcc menu. \
    `cmacc agent install --kind app` no longer does anything.
    """

  /// Where `~/Library/LaunchAgents` and the logs are (tests pass a temporary home).
  let paths: @Sendable () -> Paths

  init(paths: @escaping @Sendable () -> Paths = { Paths.live() }) {
    self.paths = paths
  }

  func run(_ args: [String]) async throws -> Int32 {
    let paths = paths()
    guard let sub = args.first, ["print", "install"].contains(sub),
          let parsed = parse(Array(args.dropFirst()), home: paths.home)
    else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    guard let data = AgentPlist.make(kind: parsed.kind, appPath: parsed.app, logsDir: paths.logsDir) else {
      Console.out(Self.retiredAppNotice)
      return ExitCode.success
    }
    if sub == "print" {
      FileHandle.standardOutput.write(data)
      return ExitCode.success
    }
    let helper = parsed.app.appendingPathComponent("Contents/Helpers/cmacc")
    if !FileManager.default.fileExists(atPath: helper.path) {
      Console.err("warning: \(helper.path) does not exist; pass --app <path to ClaudeMultiAcc.app>")
    }
    let target = AgentPlist.installURL(kind: parsed.kind, home: paths.home)
    Console.out("LaunchAgent: \(target.path)")
    guard Confirmation.ask("Install to ~/Library/LaunchAgents? [y/N] ", yes: parsed.yes) else {
      Console.err("aborted")
      return ExitCode.failure
    }
    try AtomicFile.write(data, to: target, permissions: 0o644)
    Console.out("Written. To load it, run:\n  launchctl bootstrap gui/\(getuid()) \"\(target.path)\"")
    return ExitCode.success
  }

  private func parse(_ args: [String], home: URL) -> (kind: AgentKind, app: URL, yes: Bool)? {
    var kind: AgentKind?
    var app = OwnApp.live(home: home)
    var yes = false
    var index = 0
    while index < args.count {
      switch args[index] {
      case "--kind":
        guard index + 1 < args.count, let value = AgentKind(argument: args[index + 1]) else { return nil }
        kind = value
        index += 1
      case "--app":
        guard index + 1 < args.count else { return nil }
        app = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        index += 1
      case "--yes": yes = true
      default: return nil
      }
      index += 1
    }
    return kind.map { ($0, app, yes) }
  }
}
