import AppKit
import Foundation
import LinkRouter
import Support

/// `cmacc route --dry-run <url> [--json]`: what the sign-in router would do with a link. Never delivers it and never
/// changes the `claude://` handler.
struct RouteCommand: Command {
  static let name = "route"
  static let summary = "Show where the sign-in router would send a claude:// link: route --dry-run <url> [--json]"
  private static let usageText = "Usage: cmacc route --dry-run <url> [--json]"

  /// Where the registry lives (tests pass a temporary one).
  let paths: @Sendable () -> Paths
  let runningBundleIds: @Sendable () -> Set<String>

  init(
    paths: @escaping @Sendable () -> Paths = { Paths.live() },
    runningBundleIds: @escaping @Sendable () -> Set<String> = {
      Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
  ) {
    self.paths = paths
    self.runningBundleIds = runningBundleIds
  }

  /// The link and `--json`; nil unless the arguments are `--dry-run`, one URL and optionally `--json`.
  static func parse(_ args: [String]) -> (url: URL, json: Bool)? {
    guard args.contains("--dry-run") else { return nil }
    let values = args.filter { !["--dry-run", "--json"].contains($0) }
    guard values.count == 1, !values[0].hasPrefix("-"), let url = URL(string: values[0]) else { return nil }
    return (url, args.contains("--json"))
  }

  func run(_ args: [String]) async throws -> Int32 {
    guard let (url, json) = Self.parse(args) else {
      Console.err(args.contains("--dry-run") ? Self.usageText : "cmacc route: only dry-run is supported\n\(Self.usageText)")
      return ExitCode.usage
    }
    let report = try await report(for: url)
    Console.out(json ? String(decoding: try JSONCoding.encoder.encode(report), as: UTF8.self) : report.text)
    return ExitCode.success
  }

  /// Without the app's launch history a clone counts as waiting when it runs and is not signed in.
  func report(for url: URL) async throws -> SignInReport {
    let paths = paths()
    let instances = try await InstanceStore(paths: paths).load()
    let fallback = OfficialApp.installedDefault()
    return SignInReport.dryRun(
      url: url, instances: instances, runningBundleIds: runningBundleIds(),
      ownApp: OwnApp.live(home: paths.home), officialFallback: fallback)
  }
}
