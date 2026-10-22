import Foundation

/// This module's user-facing strings: `Resources/{en,ru}.lproj/Localizable.strings` (plurals in `.stringsdict`).
/// Keys are dotted names (`"menu.edit"`); call sites go through the typed accessors of each feature.
enum SupportText {
  static let table = LocalizedTable(bundleNamed: "ClaudeMultiAcc_Support", anchor: BundleAnchor.self)

  static func string(_ key: String) -> String { table.string(key) }

  static func format(_ key: String, _ arguments: any CVarArg...) -> String { table.format(key, arguments) }
}

/// Finds the resource bundle of this module from inside a test bundle.
private final class BundleAnchor {}
