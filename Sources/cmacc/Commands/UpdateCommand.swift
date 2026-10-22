import Foundation
import InstanceBuilder
import Support

/// `cmacc update check [--apply-when-idle]`: one UpdateWatcher pass. Without the flag nothing is built
/// (`would-rebuild`); with it (the LaunchAgent) cmacc-built clones are rebuilt and swapped when idle.
struct UpdateCommand: Command {
  static let name = "update"
  static let summary = "Clone updates: update check [--apply-when-idle]"

  func run(_ args: [String]) async throws -> Int32 {
    guard args.first == "check", args.dropFirst().allSatisfy({ $0 == "--apply-when-idle" }) else {
      Console.err("Usage: cmacc update check [--apply-when-idle]")
      return ExitCode.usage
    }
    let paths = Paths.live()
    try paths.ensureDataDirs()
    let launcher = InstanceCommand.launcherURL(InstanceOptions(positional: [], values: [:], lists: [:], flags: []))
    let watcher = UpdateWatcher.live(paths: paths, runner: SystemProcessRunner(), launcherBinary: launcher)
    let decisions = await watcher.evaluate(apply: args.contains("--apply-when-idle"))
    decisions.forEach { Console.out($0.line) }
    if decisions.isEmpty { Console.out("no clones") }
    return decisions.contains { $0.action == .fail } ? ExitCode.failure : ExitCode.success
  }
}
