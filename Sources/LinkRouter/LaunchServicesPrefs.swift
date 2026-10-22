import Foundation

/// Read-only view of `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`.
public enum LaunchServicesPrefs {
  public struct Handler: Sendable, Equatable {
    public let bundleId: String?
    public let modificationDate: Date?
  }

  public static func secureFile(home: URL) -> URL {
    home.appendingPathComponent(
      "Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist")
  }

  /// The `LSHandlers` entry for `scheme` (case-insensitive); only the bundle id and modification date are read.
  public static func handler(forScheme scheme: String, plist data: Data) -> Handler? {
    guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let handlers = root["LSHandlers"] as? [[String: Any]],
      let entry = handlers.first(where: { ($0["LSHandlerURLScheme"] as? String)?.lowercased() == scheme.lowercased() })
    else { return nil }
    let date: Date? = switch entry["LSHandlerModificationDate"] {
    case let number as NSNumber: Date(timeIntervalSinceReferenceDate: number.doubleValue)
    case let value as Date: value
    default: nil
    }
    return Handler(bundleId: entry["LSHandlerRoleAll"] as? String, modificationDate: date)
  }
}
