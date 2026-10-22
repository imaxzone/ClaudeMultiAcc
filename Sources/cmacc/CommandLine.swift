import Foundation

/// One `cmacc` subcommand. New commands live in `Sources/cmacc/Commands/` and are registered in `CommandRouter.standard`.
protocol Command: Sendable {
  static var name: String { get }
  static var summary: String { get }
  func run(_ args: [String]) async throws -> Int32
}

enum ExitCode {
  static let success: Int32 = 0
  static let failure: Int32 = 1
  static let usage: Int32 = 64
}

enum Console {
  static func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
  static func err(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
}

/// Hand-written argument router: `cmacc <command> [args…]`.
struct CommandRouter: Sendable {
  private let commands: [String: any Command]
  private let aliases: [String: String] = ["--version": "version", "-V": "version"]

  init(_ commands: [any Command]) {
    self.commands = Dictionary(commands.map { (type(of: $0).name, $0) }, uniquingKeysWith: { first, _ in first })
  }

  static let standard = CommandRouter([
    VersionCommand(), InstancesCommand(), InstanceCommand(), RouteCommand(), SchemeCommand(),
    UpdateCommand(), AgentCommand(), UISnapshotCommand(),
  ])

  func run(_ arguments: [String]) async -> Int32 {
    guard let first = arguments.first else {
      Console.err(usage)
      return ExitCode.usage
    }
    if ["--help", "-h", "help"].contains(first) {
      Console.out(usage)
      return ExitCode.success
    }
    guard let command = commands[aliases[first] ?? first] else {
      Console.err("cmacc: unknown command '\(first)'\n\n\(usage)")
      return ExitCode.usage
    }
    do {
      return try await command.run(Array(arguments.dropFirst()))
    } catch {
      Console.err("cmacc \(first): \(error)")
      return ExitCode.failure
    }
  }

  var usage: String {
    let width = commands.keys.map(\.count).max() ?? 0
    let lines = commands.keys.sorted().map { name in
      let summary = commands[name].map { type(of: $0).summary } ?? ""
      return "  \(name.padding(toLength: width, withPad: " ", startingAt: 0))  \(summary)"
    }
    return (["Usage: cmacc <command> [options]", "", "Commands:"] + lines
      + ["", "Options:", "  --help, -h     Show this help", "  --version, -V  Print the version"])
      .joined(separator: "\n")
  }
}
