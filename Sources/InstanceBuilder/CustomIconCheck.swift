import Darwin
import Foundation

/// Read-only inspection of a bundle root for the Finder custom icon that clones built before the badge moved into
/// `electron.icns` still carry (`Icon\r` plus the `com.apple.FinderInfo` attribute that `NSWorkspace.setIcon` wrote).
/// New builds never have one (`BadgeStep`); old clones lose it at their next rebuild, when the bundle is replaced.
///
/// Why verification tolerates it on those old clones: that badge was applied after signing, so `Icon\r` is not sealed
/// and `codesign --verify --strict` reports the bundle root as containing unsealed contents. That does not affect
/// launch, TCC or Keychain (the code and its sealed resources are unchanged). `cmacc instance verify` therefore drops
/// `--strict` only when this icon is present and instead requires that nothing but `Contents` and `Icon\r` sits in the
/// bundle root (`unsealedEntries`).
public enum CustomIconCheck {
  public static let iconFile = "Icon\r"
  static let finderInfo = "com.apple.FinderInfo"
  static let sealedRootEntries: Set<String> = ["Contents", iconFile]

  public struct Inspection: Sendable, Equatable {
    /// `Icon\r` exists in the bundle root.
    public let present: Bool
    /// The bundle root directory carries `com.apple.FinderInfo`.
    public let finderInfo: Bool
    /// Root entries other than `Contents` and `Icon\r`, sorted.
    public let unsealedEntries: [String]
  }

  public static func inspect(_ app: URL) -> Inspection {
    let present = FileManager.default.fileExists(atPath: app.appendingPathComponent(iconFile).path)
    let hasFinderInfo = getxattr(app.path, finderInfo, nil, 0, 0, 0) >= 0
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
    return Inspection(present: present, finderInfo: hasFinderInfo,
                      unsealedEntries: entries.filter { !sealedRootEntries.contains($0) }.sorted())
  }

  /// `custom-icon` (informational pass) and `bundle-root-sealed` for a clone whose custom icon is present.
  static func checks(_ inspection: Inspection) -> (icon: SmokeCheck, root: SmokeCheck) {
    let icon = SmokeCheck(
      "custom-icon", true,
      "present (Icon\\r\(inspection.finderInfo ? " + FinderInfo" : ", no FinderInfo"); codesign run without --strict)")
    let unsealed = inspection.unsealedEntries
    let root = SmokeCheck("bundle-root-sealed", unsealed.isEmpty,
                          unsealed.isEmpty ? "only Contents and Icon\\r" : "unsealed: \(unsealed.joined(separator: ", "))")
    return (icon, root)
  }
}
