import Support

struct VersionCommand: Command {
  static let name = "version"
  static let summary = "Print the cmacc version"

  func run(_ args: [String]) async throws -> Int32 {
    Console.out("cmacc \(BuildInfo.version)")
    return ExitCode.success
  }
}
