import Foundation

/// The two fields of the «Изменить…» / «Добавить» window: the app's name exactly as the Dock and Finder show it
/// («Claude mv2») and the label on its icon (up to four characters). Both are trimmed of surrounding whitespace.
public struct InstanceDraft: Sendable, Equatable {
  public static let maxNameLength = 40
  public static let maxBadgeLength = 4

  public let name: String
  public let badge: String

  public init(name: String, badge: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.badge = badge.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// At most one problem per field, name first. `editing` is the instance being changed: its own name is no clash.
  public func problems(existing: [Instance], editing: Slug? = nil) -> [InstanceDraftProblem] {
    [nameProblem(existing: existing, editing: editing), badgeProblem()].compactMap { $0 }
  }

  private func nameProblem(existing: [Instance], editing: Slug?) -> InstanceDraftProblem? {
    if name.isEmpty { return .emptyName }
    if Self.hasControlCharacters(name) { return .nameControlCharacters }
    if name.hasPrefix(".") || name.contains("/") || name.contains(":") { return .nameNotAFileName }
    if name.count > Self.maxNameLength { return .nameTooLong(name.count) }
    let key = Self.comparable(name)
    if let other = existing.first(where: { $0.slug != editing && Self.comparable($0.name) == key }) {
      return .nameTaken(other.name)
    }
    return nil
  }

  private func badgeProblem() -> InstanceDraftProblem? {
    if badge.isEmpty { return .emptyBadge }
    if Self.hasControlCharacters(badge) { return .badgeControlCharacters }
    if badge.count > Self.maxBadgeLength { return .badgeTooLong(badge.count) }
    return nil
  }

  /// Whether two app names are the same file name in the Applications folder (letter case and Unicode
  /// normalization ignored, surrounding whitespace trimmed).
  public static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
    comparable(lhs) == comparable(rhs)
  }

  /// App names are file names: the Applications folder ignores letter case and Unicode normalization.
  static func comparable(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
  }

  /// Control characters (tab, newline, bell…), line/paragraph separators and the invisible direction overrides that
  /// can disguise a file name. Zero-width joiners inside emoji stay allowed.
  static func hasControlCharacters(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      switch scalar.properties.generalCategory {
      case .control, .lineSeparator, .paragraphSeparator: true
      default: directionControls.contains(scalar.value)
      }
    }
  }

  private static let directionControls: Set<UInt32> = [
    0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069,
  ]
}

/// Which field of the window a problem is shown under.
public enum InstanceDraftField: Sendable, Equatable {
  case name, badge
}

public enum InstanceDraftProblem: Error, Sendable, Equatable {
  case emptyName
  case nameTooLong(Int)
  case nameControlCharacters
  /// `/`, `:` or a leading dot: the name is the app's file name.
  case nameNotAFileName
  /// Another instance already has this name (letter case ignored); its name as written.
  case nameTaken(String)
  case emptyBadge
  case badgeTooLong(Int)
  case badgeControlCharacters

  public var field: InstanceDraftField {
    switch self {
    case .emptyName, .nameTooLong, .nameControlCharacters, .nameNotAFileName, .nameTaken: .name
    case .emptyBadge, .badgeTooLong, .badgeControlCharacters: .badge
    }
  }

  /// The window's text, in the UI language.
  public var message: String {
    switch self {
    case .emptyName: SupportText.string("draft.empty-name")
    case .nameTooLong(let count): SupportText.format("draft.name-too-long", InstanceDraft.maxNameLength, count)
    case .nameControlCharacters: SupportText.string("draft.name-control")
    case .nameNotAFileName: SupportText.string("draft.name-not-file-name")
    case .nameTaken(let name): SupportText.format("draft.name-taken", name)
    case .emptyBadge: SupportText.string("draft.empty-badge")
    case .badgeTooLong(let count): SupportText.format("draft.badge-too-long", InstanceDraft.maxBadgeLength, count)
    case .badgeControlCharacters: SupportText.string("draft.badge-control")
    }
  }
}

extension InstanceDraftProblem: CustomStringConvertible {
  /// English, for logs.
  public var description: String {
    switch self {
    case .emptyName: "name is empty"
    case .nameTooLong(let count): "name is \(count) characters long (max \(InstanceDraft.maxNameLength))"
    case .nameControlCharacters: "name contains control characters"
    case .nameNotAFileName: "name contains '/' or ':' or starts with a dot"
    case .nameTaken(let name): "name \"\(name)\" is already used"
    case .emptyBadge: "badge is empty"
    case .badgeTooLong(let count): "badge is \(count) characters long (max \(InstanceDraft.maxBadgeLength))"
    case .badgeControlCharacters: "badge contains control characters"
    }
  }
}
