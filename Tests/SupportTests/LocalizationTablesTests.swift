import Foundation
import Testing

/// The string tables as they are in the source tree (`Sources/<Module>/Resources/<language>.lproj`; SwiftPM copies them
/// unchanged): both languages parse and have the same keys with the same format arguments, plurals have every form
/// their language needs, the code uses exactly the keys there are, and no Swift code outside comments is Russian.
@Suite struct LocalizationTablesTests {
  /// Module → the enum its code reads the table through.
  static let modules = ["Support": "SupportText", "InstanceBuilder": "BuilderText", "UI": "UIText"]
  static let pluralForms = ["en": ["one", "other"], "ru": ["one", "few", "many", "other"]]
  static let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources", isDirectory: true)

  @Test(arguments: modules.keys.sorted())
  func bothLanguagesHaveTheSameKeysAndArguments(module: String) throws {
    let english = try LocalizationTable(module: module, language: "en")
    let russian = try LocalizationTable(module: module, language: "ru")
    #expect(!english.keys.isEmpty)
    #expect(english.keys == russian.keys, "\(module): \(english.keys.symmetricDifference(russian.keys).sorted())")
    for key in english.keys.intersection(russian.keys).sorted() {
      #expect(english.arguments[key] == russian.arguments[key], "\(module) \(key)")
    }
    #expect(english.duplicates.isEmpty && russian.duplicates.isEmpty, "\(english.duplicates + russian.duplicates)")
    #expect(english.inBothFiles.isEmpty && russian.inBothFiles.isEmpty, "\(english.inBothFiles + russian.inBothFiles)")
    for table in [english, russian] {
      for (key, forms) in table.pluralForms {
        #expect(Set(forms).isSuperset(of: Self.pluralForms[table.language] ?? []), "\(module) \(table.language) \(key)")
      }
      #expect(table.formProblems.isEmpty, "\(module) \(table.language): \(table.formProblems)")
    }
  }

  @Test(arguments: modules.keys.sorted())
  func codeUsesExactlyTheKeysOfTheTable(module: String) throws {
    let accessor = try #require(Self.modules[module])
    let table = try LocalizationTable(module: module, language: "en")
    var used: Set<String> = []
    for file in try Self.swiftFiles(in: module) {
      for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines) {
        let calls = ["string(", "format("].compactMap { line.range(of: "\(accessor).\($0)")?.lowerBound }
        guard let first = calls.min() else { continue }
        used.formUnion(Self.keyLiterals(in: String(line[first...])))
      }
    }
    #expect(used.subtracting(table.keys).isEmpty, "\(module): not in the table \(used.subtracting(table.keys).sorted())")
    #expect(table.keys.subtracting(used).isEmpty, "\(module): unused \(table.keys.subtracting(used).sorted())")
  }

  @Test func noRussianOutsideCommentsInSwiftCode() throws {
    let modules = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { !$0.hasPrefix(".") }
    #expect(modules.contains("UI") && modules.contains("InstanceBuilder"))
    var offending: [String] = []
    for module in modules {
      for file in try Self.swiftFiles(in: module) {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where Self.hasCyrillic(Self.code(of: line)) {
          offending.append("\(module)/\(file.lastPathComponent):\(index + 1)")
        }
      }
    }
    #expect(offending.isEmpty, "\(offending)")
  }

  @Test func commentsAndStringsAreToldApart() {
    #expect(!Self.hasCyrillic(Self.code(of: "  /// «Изменить…»")))
    #expect(Self.code(of: #"let url = "https://x" // ссылка"#) == #"let url = "https://x" "#)
    #expect(Self.hasCyrillic(Self.code(of: #"  text = "Отмена""#)))
    #expect(Self.keyLiterals(in: #"UIText.format(n == 1 ? "status.deleting.one" : "status.deleting.many", x)"#)
      == ["status.deleting.one", "status.deleting.many"])
  }

  // MARK: Helpers

  static func swiftFiles(in module: String) throws -> [URL] {
    let root = sources.appendingPathComponent(module, isDirectory: true)
    let paths = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
    return paths.filter { $0.hasSuffix(".swift") }.sorted().map { root.appendingPathComponent($0) }
  }

  /// The line without its `//` comment (a `//` inside a string literal stays).
  static func code(of line: String) -> String {
    var inString = false
    var previous: Character = " "
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      if character == "\"" && previous != "\\" { inString.toggle() }
      if !inString, character == "/", previous == "/" { return String(line[..<line.index(before: index)]) }
      previous = character
      index = line.index(after: index)
    }
    return line
  }

  static func hasCyrillic(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
  }

  /// String literals shaped like a key: `"menu.edit"`, `"update.confirm-title.one"`.
  static func keyLiterals(in text: String) -> [String] {
    text.matches(of: /"([a-z]+(?:\.[a-z0-9-]+)+)"/).map { String($0.output.1) }
  }
}

/// One language of one module: `Localizable.strings` and `Localizable.stringsdict` parsed, with each key's format
/// arguments by position (`[1: "@", 2: "ld"]`).
struct LocalizationTable {
  let language: String
  private(set) var keys: Set<String> = []
  private(set) var arguments: [String: [Int: String]] = [:]
  private(set) var pluralForms: [String: [String]] = [:]
  private(set) var duplicates: [String] = []
  private(set) var inBothFiles: [String] = []
  private(set) var formProblems: [String] = []

  init(module: String, language: String) throws {
    self.language = language
    let lproj = LocalizationTablesTests.sources
      .appendingPathComponent("\(module)/Resources/\(language).lproj", isDirectory: true)
    let stringsURL = lproj.appendingPathComponent("Localizable.strings")
    let text = try String(contentsOf: stringsURL, encoding: .utf8)
    let strings = try #require(
      try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: String])
    let declared = text.matches(of: /(?m)^"([^"]+)"\s*=/).map { String($0.output.1) }
    duplicates = Dictionary(grouping: declared, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    for (key, value) in strings {
      keys.insert(key)
      arguments[key] = Self.arguments(of: value)
    }
    let dictURL = lproj.appendingPathComponent("Localizable.stringsdict")
    guard FileManager.default.fileExists(atPath: dictURL.path) else { return }
    let plurals = try #require(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: dictURL), format: nil) as? [String: Any])
    for (key, entry) in plurals {
      if keys.contains(key) { inBothFiles.append(key) }
      keys.insert(key)
      try readPlural(key, entry)
    }
  }

  private mutating func readPlural(_ key: String, _ entry: Any) throws {
    let entry = try #require(entry as? [String: Any], "\(key)")
    let format = try #require(entry["NSStringLocalizedFormatKey"] as? String, "\(key)")
    var positions: [Int: String] = [:]
    for (offset, spec) in Self.specifiers(format).enumerated() {
      let position = spec.position ?? offset + 1
      guard let variable = spec.variable else {
        positions[position] = spec.type
        continue
      }
      let rule = try #require(entry[variable] as? [String: String], "\(key): \(variable)")
      let type = rule["NSStringFormatValueTypeKey"] ?? "?"
      positions[position] = type
      let forms = rule.filter { !$0.key.hasPrefix("NSString") }
      pluralForms[key] = forms.keys.sorted()
      for (form, text) in forms where Self.specifiers(text).contains(where: { $0.type != type }) {
        formProblems.append("\(key).\(form)")
      }
    }
    arguments[key] = positions
  }

  static func arguments(of text: String) -> [Int: String] {
    var positions: [Int: String] = [:]
    for (offset, spec) in specifiers(text).enumerated() { positions[spec.position ?? offset + 1] = spec.type }
    return positions
  }

  struct Specifier: Equatable {
    let position: Int?
    let type: String
    let variable: String?
  }

  /// `%@`, `%1$@`, `%ld`, `%2$#@seconds@`; `%%` is not an argument.
  static func specifiers(_ text: String) -> [Specifier] {
    text.matches(of: /%(?:(\d+)\$)?(?:#@(\w+)@|[-+ #0']*\d*(?:\.\d+)?((?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSaAp%]))/)
      .compactMap { match -> Specifier? in
        let position = match.output.1.flatMap { Int($0) }
        if let variable = match.output.2 { return Specifier(position: position, type: "#@", variable: String(variable)) }
        let type = match.output.3.map(String.init) ?? ""
        return type == "%" ? nil : Specifier(position: position, type: type, variable: nil)
      }
  }
}
