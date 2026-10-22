import Foundation
import LinkRouter
import Support

/// `cmacc scheme owner [--json]`: the current `claude://` handler (read-only; never changes it).
struct SchemeCommand: Command {
  static let name = "scheme"
  static let summary = "Show the claude:// handler: scheme owner [--json]"

  private struct Output: Encodable {
    let bundleId: String?
    let path: String?
    let lsHandlerBundleId: String?
    let lsHandlerModificationDate: String?
  }

  func run(_ args: [String]) async throws -> Int32 {
    guard args.first == "owner", args.dropFirst().allSatisfy({ $0 == "--json" }) else {
      Console.err("Usage: cmacc scheme owner [--json]")
      return ExitCode.usage
    }
    let paths = Paths.live()
    let ownApp = paths.home.appendingPathComponent("Applications/ClaudeMultiAcc.app")
    let owner = SchemeOwnership.system(ownApp: ownApp).owner()
    let prefs = (try? Data(contentsOf: LaunchServicesPrefs.secureFile(home: paths.home)))
      .flatMap { LaunchServicesPrefs.handler(forScheme: SchemeOwnership.scheme, plist: $0) }
    let output = Output(
      bundleId: owner.bundleId, path: owner.path?.path, lsHandlerBundleId: prefs?.bundleId,
      lsHandlerModificationDate: prefs?.modificationDate.map { $0.formatted(.iso8601) })
    if args.contains("--json") {
      Console.out(String(decoding: try JSONCoding.encoder.encode(output), as: UTF8.self))
    } else {
      Console.out("\(output.bundleId ?? "-") \(output.path ?? "-")")
      Console.out("LSHandlers: \(output.lsHandlerBundleId ?? "-") modified \(output.lsHandlerModificationDate ?? "-")")
    }
    return ExitCode.success
  }
}
