import Foundation

/// The instances known when the tool is first run. Used only to create `instances.json` when it is missing (G20).
/// A new user starts with only the official Claude: its account and organisation are not known in advance (they are
/// read from its profile), and every clone is added later from the menu. Seeded even when `/Applications/Claude.app`
/// is missing: clones are built from it anyway, and an entry written now keeps working once Claude is installed.
public enum InstanceSeeds {
  public static func seeds(home: URL) -> [Instance] {
    let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    return [
      Instance(
        slug: fixed("main"), name: "Claude", kind: .official, bundleId: "com.anthropic.claudefordesktop",
        appPath: "/Applications/Claude.app", profileDir: support.appendingPathComponent("Claude").path,
        builtBy: "vendor"),
    ]
  }

  private static func fixed(_ raw: String) -> Slug {
    do {
      return try Slug(raw)
    } catch {
      preconditionFailure("Seed slug '\(raw)' is invalid")
    }
  }
}
