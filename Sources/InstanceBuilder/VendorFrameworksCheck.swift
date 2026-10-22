import Foundation
import Support

/// `vendor-frameworks-intact`: nothing under `Contents/Frameworks/` of a clone was modified or re-signed.
///
/// The vendor helpers (`Claude Helper*.app`) run with the hardened runtime and library validation. They load the
/// vendor `Electron Framework`, which links `Squirrel.framework`, `Mantle` and `ReactiveObjC`; a framework whose
/// Team ID differs from the helper's is rejected by dyld ("different Team IDs") and every helper crashes at launch.
/// Only `Claude.real` (local signature + `disable-library-validation`) would tolerate it. So every bundle directly
/// in `Contents/Frameworks` must report the source app's Team ID, and Squirrel still ships its `ShipIt`.
public struct VendorFrameworksCheck: Sendable {
  public static let name = "vendor-frameworks-intact"
  public static let frameworksPath = "Contents/Frameworks"
  public static let shipItPath = "Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt"
  private let runner: ProcessRunning

  public init(runner: ProcessRunning) {
    self.runner = runner
  }

  /// The `TeamIdentifier` of `codesign -dv --verbose=2 <bundle>`; nil when unsigned or unreadable.
  public static func teamId(of bundle: URL, runner: ProcessRunning) async throws -> String? {
    let result = try await runner.runTool(BuilderTool.codesign, ["-dv", "--verbose=2", bundle.path], timeout: BuilderTool.shortTimeout)
    guard result.exitCode == 0 else { return nil }
    return Verifier.value(of: "TeamIdentifier", in: result.stderrText + result.stdoutText)
  }

  /// Compares against `reference` (captured from the source before `recheck-source`); never reads the source.
  public func run(app: URL, reference: SourceFacts) async throws -> SmokeCheck {
    guard let expected = reference.teamId else { return SmokeCheck(Self.name, false, "source Team ID unknown") }
    let bundles = Self.bundleNames(in: app)
    guard !bundles.isEmpty else { return SmokeCheck(Self.name, false, "no bundles in \(Self.frameworksPath)") }
    var foreign: [String] = []
    for name in bundles {
      let team = try await Self.teamId(of: app.appendingPathComponent("\(Self.frameworksPath)/\(name)"), runner: runner)
      if team != expected { foreign.append("\(name)=\(team ?? "unsigned")") }
    }
    let shipItMissing = reference.hasShipIt && !Self.hasShipIt(app)
    var problems: [String] = []
    if !foreign.isEmpty { problems.append("Team ID differs: \(foreign.joined(separator: ", ")) (expected \(expected))") }
    if shipItMissing { problems.append("ShipIt missing from Squirrel.framework") }
    guard problems.isEmpty else { return SmokeCheck(Self.name, false, problems.joined(separator: "; ")) }
    let shipIt = reference.hasShipIt ? "ShipIt present" : "source has no ShipIt"
    return SmokeCheck(Self.name, true, "\(bundles.count) bundles signed by \(expected), \(shipIt)")
  }

  /// `*.framework` and `*.app` directly in `Contents/Frameworks`, sorted.
  static func bundleNames(in app: URL) -> [String] {
    let dir = app.appendingPathComponent(frameworksPath)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".framework") || $0.hasSuffix(".app") }.sorted()
  }

  static func hasShipIt(_ app: URL) -> Bool {
    FileManager.default.fileExists(atPath: app.appendingPathComponent(shipItPath).path)
  }
}
