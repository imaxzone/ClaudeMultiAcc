import Foundation

/// The language of every user-facing string: English (the development language) or Russian, as macOS picks it for
/// this process from the preferred languages. The app's Info.plist lists both (`CFBundleLocalizations`), so the app
/// follows the user's order; a bare tool such as `cmacc` has no list and stays English. Logs are never localized.
public enum Localization {
  public static let developmentLanguage = "en"
  public static let languages = ["en", "ru"]

  /// Pins the language for the current task and its children (tests, review shots); nil follows macOS.
  @TaskLocal public static var pinned: String?

  /// What macOS chose for this process, once.
  public static let system: String = choose(from: Bundle.preferredLocalizations(from: languages))

  /// The language strings are looked up in now.
  public static var language: String {
    pinned.map { choose(from: [$0]) } ?? system
  }

  /// Numbers, byte sizes and lists: the user's region in the current language. A pinned language formats with a
  /// fixed locale, so tests do not depend on the machine's settings.
  public static var locale: Locale {
    if let pinned { return Locale(identifier: choose(from: [pinned]) == "ru" ? "ru_RU" : "en_US") }
    let current = Locale.current
    guard current.language.languageCode?.identifier != system else { return current }
    return Locale(identifier: system + (current.region.map { "_\($0.identifier)" } ?? ""))
  }

  /// "a and b", "a, b and c" in the current language.
  public static func list(_ items: [String]) -> String {
    items.formatted(.list(type: .and).locale(locale))
  }

  /// `632 MB`, `12,6 ГБ`: a file size in the current locale.
  public static func byteCount(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file).locale(locale))
  }

  /// The first supported language among `candidates` (`ru-RU` counts as `ru`), else English.
  static func choose(from candidates: [String]) -> String {
    for candidate in candidates {
      let code = String(candidate.prefix { $0 != "-" && $0 != "_" }).lowercased()
      if languages.contains(code) { return code }
    }
    return developmentLanguage
  }
}

/// One module's string tables: `<language>.lproj/Localizable.strings` (and `.stringsdict` for plurals) in its
/// SwiftPM resource bundle. A key missing in the current language falls back to English, then to the key itself.
public struct LocalizedTable: @unchecked Sendable {
  // `@unchecked`: `Bundle` lookups are thread-safe; the dictionary is never mutated after init.
  private let tables: [String: Bundle]
  private static let missing = "\u{1}missing"

  /// `bundle` is the module's resource bundle; nil (not found) leaves every key as it is.
  public init(bundle: Bundle?) {
    var tables: [String: Bundle] = [:]
    for language in Localization.languages {
      if let url = bundle?.url(forResource: language, withExtension: "lproj"), let lproj = Bundle(url: url) {
        tables[language] = lproj
      }
    }
    self.tables = tables
  }

  /// The resource bundle `<name>.bundle` wherever SwiftPM or `bundle-app.sh` put it (see `ResourceBundles`).
  public init(bundleNamed name: String, anchor: AnyClass) {
    self.init(bundle: ResourceBundles.find(name, anchor: anchor))
  }

  /// The languages this table has, for tests.
  public var availableLanguages: [String] { Localization.languages.filter { tables[$0] != nil } }

  /// The `.lproj` bundle of `language`, for tests that read a table directly.
  public func lproj(_ language: String) -> Bundle? { tables[language] }

  public func string(_ key: String) -> String {
    for language in [Localization.language, Localization.developmentLanguage] {
      if let found = tables[language]?.localizedString(forKey: key, value: Self.missing, table: nil),
         found != Self.missing {
        return found
      }
    }
    return key
  }

  /// The format of `key` filled with `arguments` in the current locale; a `.stringsdict` entry picks its plural form.
  public func format(_ key: String, _ arguments: [any CVarArg]) -> String {
    String(format: string(key), locale: Localization.locale, arguments: arguments)
  }
}
