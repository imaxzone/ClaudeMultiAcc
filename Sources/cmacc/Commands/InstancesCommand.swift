import Foundation
import Support

/// `cmacc instances list|remove|edit`: the ordered instance registry. `remove` and `edit` change `instances.json`
/// only — apps, profiles and CLI folders are never touched.
struct InstancesCommand: Command {
  static let name = "instances"
  static let summary = "Instance registry: instances list [--json] | remove <slug> [--yes] | edit <slug> [...]"
  static let usageText = """
    Usage:
      cmacc instances list [--json]
      cmacc instances remove <slug> [--yes]
      cmacc instances edit <slug> [--name <name>] [--badge <text>] [--emails a@x,b@y] [--clear-emails]
    """

  /// Where the registry lives (tests pass a temporary one).
  let paths: @Sendable () -> Paths

  init(paths: @escaping @Sendable () -> Paths = { Paths.live() }) {
    self.paths = paths
  }

  func run(_ args: [String]) async throws -> Int32 {
    switch args.first {
    case "list" where args.dropFirst().allSatisfy({ $0 == "--json" }): return try await list(json: args.contains("--json"))
    case "remove": return try await remove(Array(args.dropFirst()))
    case "edit": return try await edit(Array(args.dropFirst()))
    default:
      Console.err(Self.usageText)
      return ExitCode.usage
    }
  }

  private func list(json: Bool) async throws -> Int32 {
    let instances = try await InstanceStore(paths: paths()).loadOrSeed()
    Console.out(json ? String(decoding: try JSONCoding.encoder.encode(instances), as: UTF8.self) : Self.table(instances))
    return ExitCode.success
  }

  private func remove(_ args: [String]) async throws -> Int32 {
    let yes = args.contains("--yes")
    let rest = args.filter { $0 != "--yes" }
    guard rest.count == 1, let slug = try? Slug(rest[0]) else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    let store = InstanceStore(paths: paths())
    guard let instance = try await store.load().first(where: { $0.slug == slug }) else {
      throw InstanceEditError.notFound(slug.raw)
    }
    guard instance.kind != .official else { throw InstanceEditError.officialNotRemovable(slug.raw) }
    let prompt = "Remove \"\(instance.name)\" (\(slug.raw)) from instances.json? Its app and profile stay on disk. [y/N] "
    guard Confirmation.ask(prompt, yes: yes) else {
      Console.err("aborted")
      return ExitCode.failure
    }
    let removed = try await store.removeEntry(slug: slug)
    Console.out("Removed \(slug.raw) from instances.json.")
    let left = removed.leftOnDisk(paths: paths())
    if !left.isEmpty { Console.out((["Left on disk (delete by hand if you no longer need it):"] + left.map { "  \($0)" }).joined(separator: "\n")) }
    return ExitCode.success
  }

  private func edit(_ args: [String]) async throws -> Int32 {
    guard let parsed = EditOptions.parse(args) else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    let edited = try await InstanceStore(paths: paths()).edit(slug: parsed.slug, parsed.edit)
    Console.out("\(edited.slug.raw): name \"\(edited.name)\", badge \(edited.badge ?? "-"), emails "
      + (edited.emails.isEmpty ? "-" : edited.emails.joined(separator: ",")))
    return ExitCode.success
  }

  /// One line per instance: `slug  kind  bundleId  appPath`, columns aligned, "-" for missing values.
  static func table(_ instances: [Instance]) -> String {
    let rows = instances.map { [$0.slug.raw, $0.kind.rawValue, $0.bundleId ?? "-", $0.appPath ?? "-"] }
    let widths = (0..<4).map { column in rows.map { $0[column].count }.max() ?? 0 }
    return rows.map { row in
      row.enumerated().map { index, cell in
        index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
      }.joined(separator: "  ")
    }.joined(separator: "\n")
  }
}

/// `edit <slug> [--name N] [--badge B] [--emails a,b] [--clear-emails]`; at least one change, never both email flags.
struct EditOptions: Equatable {
  let slug: Slug
  let edit: InstanceEdit

  static func parse(_ args: [String]) -> EditOptions? {
    guard let raw = args.first, !raw.hasPrefix("--"), let slug = try? Slug(raw),
          let options = InstanceOptions.parse(Array(args.dropFirst()), valueKeys: ["--name", "--badge", "--emails"],
                                              flagKeys: ["--clear-emails"]),
          options.positional.isEmpty
    else { return nil }
    let clear = options.flags.contains("--clear-emails")
    let listed = options.values["--emails"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    guard !(clear && listed != nil) else { return nil }
    let edit = InstanceEdit(name: options.values["--name"], badge: options.values["--badge"], emails: clear ? [] : listed)
    guard edit != InstanceEdit() else { return nil }
    return EditOptions(slug: slug, edit: edit)
  }
}
