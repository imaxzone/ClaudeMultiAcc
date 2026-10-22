import Foundation

/// Reduces the vendor entitlements to what an ad hoc / self-signed clone may carry (D3).
public enum EntitlementsFilter {
  static let removedKeys: Set<String> = [
    "com.apple.application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups",
    "com.apple.security.application-groups",
  ]
  static let removedPrefix = "com.apple.developer."
  static let forbiddenKeys = [
    "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.get-task-allow",
    "com.apple.security.cs.disable-executable-page-protection",
  ]
  static let libraryValidationKey = "com.apple.security.cs.disable-library-validation"

  /// `xml` is the output of `codesign -d --entitlements - --xml`; empty input means "no entitlements".
  public static func filter(_ xml: Data) throws -> Data {
    let source = try decode(xml)
    for key in forbiddenKeys where (source[key] as? Bool) == true {
      throw BuilderError.forbiddenEntitlement(key)
    }
    var result = source.filter { key, _ in !removedKeys.contains(key) && !key.hasPrefix(removedPrefix) }
    result[libraryValidationKey] = true
    do {
      return try PropertyListSerialization.data(fromPropertyList: result, format: .xml, options: 0)
    } catch {
      throw BuilderError.invalidPlist("entitlements encode: \(error.localizedDescription)")
    }
  }

  static func decode(_ xml: Data) throws -> [String: Any] {
    if xml.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
    guard let object = try? PropertyListSerialization.propertyList(from: xml, format: nil),
          let dict = object as? [String: Any]
    else { throw BuilderError.invalidPlist("entitlements are not a dictionary") }
    return dict
  }
}
