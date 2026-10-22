import Foundation
import Support

/// What `StaticSmoke` compares a clone against, read from the source once. The pipeline reads it before
/// `recheck-source`, so a vendor update replacing the source later cannot leak into the checks.
public struct SourceFacts: Sendable, Equatable {
  /// Nested `*.app` bundle ids in `Contents/Frameworks` and `Contents/Helpers`, keyed by relative path.
  public let helperIds: [String: String]
  /// `ElectronAsarIntegrity` of the source Info.plist as an XML property list, nil when absent.
  public let asarIntegrity: Data?
  /// SHA-256 of `Contents/Resources/electron.icns`, nil when unreadable.
  public let icnsSHA256: String?
  /// `TeamIdentifier` of the source app's signature (every vendor framework must keep it), nil when unknown.
  public let teamId: String?
  /// Whether the source ships `Squirrel.framework/…/ShipIt` (the clone then must too: Frameworks stay untouched).
  public let hasShipIt: Bool

  public init(helperIds: [String: String], asarIntegrity: Data?, icnsSHA256: String?, teamId: String?, hasShipIt: Bool) {
    self.helperIds = helperIds
    self.asarIntegrity = asarIntegrity
    self.icnsSHA256 = icnsSHA256
    self.teamId = teamId
    self.hasShipIt = hasShipIt
  }

  static let asarKey = "ElectronAsarIntegrity"
  static let icnsPath = "Contents/Resources/electron.icns"

  /// File facts of `source` plus a Team ID the caller already read (the pipeline takes it from `SourceProbe`).
  public static func read(from source: URL, teamId: String?) -> SourceFacts {
    let info = (try? PlistPatcher.decode(Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")))) ?? [:]
    return SourceFacts(
      helperIds: StaticSmoke.nestedAppIds(in: source), asarIntegrity: encode(info[asarKey]),
      icnsSHA256: StaticSmoke.sha256(of: source.appendingPathComponent(icnsPath)), teamId: teamId,
      hasShipIt: VendorFrameworksCheck.hasShipIt(source))
  }

  /// Reads everything from the live source, the Team ID with `codesign -dv` (`cmacc instance verify`).
  public static func read(from source: URL, runner: ProcessRunning) async throws -> SourceFacts {
    read(from: source, teamId: try await VendorFrameworksCheck.teamId(of: source, runner: runner))
  }

  static func encode(_ value: Any?) -> Data? {
    guard let value else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
  }

  static func decode(_ data: Data?) -> Any? {
    guard let data else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, format: nil)
  }
}
