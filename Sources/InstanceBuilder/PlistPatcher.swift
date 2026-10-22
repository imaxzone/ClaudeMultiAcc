import Foundation

/// Rewrites the clone's `Contents/Info.plist` (R14, G11). Pure: data in, data out.
/// A badged clone loses `CFBundleIconName` (the vendor's Assets.car icon), so macOS shows the clone's own
/// `electron.icns`, which carries the badge inside the icon shape (`BadgeStep`, R1); `Assets.car` itself stays for
/// Claude's runtime images. An unbadged clone keeps the name: the vendor's new-format icon never gets the grey
/// legacy platter, while the vendor's `electron.icns` (with 1x 16/32 pt images) would at small sizes.
public enum PlistPatcher {
  static let allowedDocumentTypes: Set<String> = ["Desktop Extension", "Skill File"]
  static let slugKey = "ClaudeMultiAccSlug"

  public static func patch(_ info: Data, spec: CloneSpec) throws -> Data {
    try CloneSpec.checkBundleId(spec.bundleId, slug: spec.slug)
    var plist = try decode(info)
    let name = plist["CFBundleName"] as? String ?? ""
    guard name == "Claude" else { throw BuilderError.unexpectedBundleName(name) }

    plist["CFBundleIdentifier"] = spec.bundleId
    plist["CFBundleDisplayName"] = spec.displayName
    plist[slugKey] = spec.slug.raw
    if spec.badge != nil { plist.removeValue(forKey: "CFBundleIconName") }
    plist["CFBundleURLTypes"] = claudeOnlyURLTypes(plist["CFBundleURLTypes"])
    plist["CFBundleDocumentTypes"] = allowedDocTypes(plist["CFBundleDocumentTypes"])
    plist = movingExportedTypes(plist)

    do {
      return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    } catch {
      throw BuilderError.invalidPlist("encode: \(error.localizedDescription)")
    }
  }

  static func decode(_ data: Data) throws -> [String: Any] {
    guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
          let dict = object as? [String: Any]
    else { throw BuilderError.invalidPlist("Info.plist is not a dictionary") }
    return dict
  }

  /// Keeps URL types whose every scheme is `claude` (drops `msauth…` and mixed entries).
  static func claudeOnlyURLTypes(_ value: Any?) -> [[String: Any]] {
    let types = value as? [[String: Any]] ?? []
    return types.filter { type in
      let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
      return !schemes.isEmpty && schemes.allSatisfy { $0 == "claude" }
    }
  }

  static func allowedDocTypes(_ value: Any?) -> [[String: Any]] {
    let types = value as? [[String: Any]] ?? []
    return types
      .filter { allowedDocumentTypes.contains($0["CFBundleTypeName"] as? String ?? "") }
      .map { $0.merging(["LSHandlerRank": "Alternate"]) { _, new in new } }
  }

  /// Moves `UTExportedTypeDeclarations` into `UTImportedTypeDeclarations`; an exported entry replaces an
  /// imported one with the same `UTTypeIdentifier`.
  static func movingExportedTypes(_ plist: [String: Any]) -> [String: Any] {
    let exported = plist["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
    guard !exported.isEmpty else {
      return plist.filter { $0.key != "UTExportedTypeDeclarations" }
    }
    let exportedIds = Set(exported.compactMap { $0["UTTypeIdentifier"] as? String })
    let imported = (plist["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
      .filter { !exportedIds.contains($0["UTTypeIdentifier"] as? String ?? "") }
    var result = plist.filter { $0.key != "UTExportedTypeDeclarations" }
    result["UTImportedTypeDeclarations"] = imported + exported
    return result
  }
}
