import Foundation
import InstanceBuilder
import Support

/// `cmacc instance rebuild second --check|--apply`: Step 6. `--check` is read-only outside the data dir;
/// `--apply` replaces `/Applications/Claude 2nd.app` and asks first (never run by this project's automation).
struct RebuildCommand {
  func run(_ options: InstanceOptions) async throws -> Int32 {
    guard options.positional == ["second"], options.flags.contains("--check") != options.flags.contains("--apply") else {
      Console.err("Usage: cmacc instance rebuild second --check [--keep-staging] [--json] | --apply [--yes]")
      return ExitCode.usage
    }
    let paths = Paths.live()
    try paths.ensureDataDirs()
    let env = RebuildEnvironment.live(
      paths: paths, runner: SystemProcessRunner(), launcherBinary: InstanceCommand.launcherURL(options))
    let rebuild = RebuildSecond(env: env)
    if options.flags.contains("--check") {
      let items = await rebuild.check(keepStaging: options.flags.contains("--keep-staging"))
      if options.flags.contains("--json") {
        Console.out(String(decoding: try JSONCoding.encoder.encode(items), as: UTF8.self))
      } else {
        items.forEach { Console.out($0.line) }
      }
      return items.allSatisfy(\.passed) ? ExitCode.success : ExitCode.failure
    }
    guard Confirmation.ask("Replace \(env.liveApp.path) with a rebuilt clone? [y/N] ", yes: options.flags.contains("--yes")) else {
      Console.err("aborted")
      return ExitCode.failure
    }
    let result = try await rebuild.apply()
    Console.out("Rebuilt \(result.live.path); backup \(result.backup.path)")
    Console.out("Rollback: \(result.rollbackCommand)")
    return ExitCode.success
  }
}

/// `cmacc instance rollback second <backup-path>`: undo `rebuild second --apply` (asks first).
struct RollbackCommand {
  func run(_ options: InstanceOptions) async throws -> Int32 {
    guard options.positional.count == 2, options.positional[0] == "second" else {
      Console.err("Usage: cmacc instance rollback second <backup-path> [--yes]")
      return ExitCode.usage
    }
    let paths = Paths.live()
    let env = RebuildEnvironment.live(
      paths: paths, runner: SystemProcessRunner(), launcherBinary: InstanceCommand.launcherURL(options))
    let backup = URL(fileURLWithPath: options.positional[1], isDirectory: true)
    guard Confirmation.ask("Restore \(backup.path) to \(env.liveApp.path)? [y/N] ", yes: options.flags.contains("--yes")) else {
      Console.err("aborted")
      return ExitCode.failure
    }
    try await RebuildSecond(env: env).rollback(backup: backup)
    Console.out("Restored \(env.liveApp.path)")
    return ExitCode.success
  }
}

/// `[y/N]` prompt on a TTY; without a TTY only `--yes` proceeds.
enum Confirmation {
  static func ask(_ prompt: String, yes: Bool) -> Bool {
    if yes { return true }
    guard isatty(STDIN_FILENO) == 1 else {
      Console.err("not a terminal: pass --yes to confirm")
      return false
    }
    FileHandle.standardError.write(Data(prompt.utf8))
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
    return answer == "y" || answer == "yes"
  }
}
