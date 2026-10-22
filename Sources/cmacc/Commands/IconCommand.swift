import Foundation
import InstanceBuilder
import Support

/// `cmacc instance icon <slug> [--label <text>]`: retired. It used to set a badged Finder custom icon (`Icon\r`) on an
/// installed clone; now the badge is baked into the clone's `electron.icns` when the clone is built (`BadgeStep`, R1),
/// inside the icon shape and sealed with the signature, so there is nothing to apply afterwards. The command only
/// explains that for the given instance (read-only) and exits with failure, since nothing was applied.
struct IconCommand {
  static let usage = "Usage: cmacc instance icon <slug>"

  private let paths: @Sendable () -> Paths

  init(paths: @escaping @Sendable () -> Paths = { Paths.live() }) {
    self.paths = paths
  }

  func run(_ options: InstanceOptions) async throws -> Int32 {
    guard options.positional.count == 1, let slug = try? Slug(options.positional[0]) else {
      Console.err(Self.usage)
      return ExitCode.usage
    }
    guard let instance = try await InstanceStore(paths: paths()).load().first(where: { $0.slug == slug }) else {
      Console.err("error: no instance '\(slug.raw)' in instances.json")
      return ExitCode.failure
    }
    Console.err(Self.explanation(for: instance))
    return ExitCode.failure
  }

  /// English, for the CLI: why nothing is applied and how the badge changes now.
  static func explanation(for instance: Instance) -> String {
    let slug = instance.slug.raw
    guard instance.kind == .clone else {
      return "'\(slug)' is \(instance.kind.rawValue), not a clone: only clones carry a badge"
    }
    let badge = instance.badge.map { "the badge «\($0)»" } ?? "no badge"
    let oldIcon = instance.appPath.map { CustomIconCheck.inspect(URL(fileURLWithPath: $0, isDirectory: true)).present }
    let lines = [
      "cmacc instance icon is retired: Finder custom icons are no longer written.",
      "'\(slug)' (\(instance.name)) has \(badge); a clone's badge is baked into its electron.icns when it is built.",
      "To change it, edit the clone in the ClaudeMultiAcc menu (it is rebuilt); a clone built before this change gets",
      "the new icon at its next rebuild (the next Claude update).",
    ]
    let note = oldIcon == true ? ["It still carries an old Finder custom icon (Icon\\r), which goes away with that rebuild."] : []
    return (lines + note).joined(separator: "\n")
  }
}
