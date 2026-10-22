import Foundation

/// A change to one entry of `instances.json` (P4); `nil` leaves a field as it is. Only the registry changes: a new
/// name or badge shows in the menu at once; a badge reaches a clone's icon with its next build or `cmacc instance icon`.
public struct InstanceEdit: Sendable, Equatable {
  public static let maxNameLength = 40
  public static let maxBadgeLength = 6

  public let name: String?
  public let badge: String?
  public let emails: [String]?

  public init(name: String? = nil, badge: String? = nil, emails: [String]? = nil) {
    self.name = name
    self.badge = badge
    self.emails = emails
  }

  /// Problems in field order: name, badge, emails.
  public func problems() -> [InstanceEditProblem] {
    var problems: [InstanceEditProblem] = []
    if let name {
      let trimmed = name.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { problems.append(.emptyName) }
      if trimmed.count > Self.maxNameLength { problems.append(.nameTooLong(trimmed.count)) }
    }
    if let badge, badge.isEmpty || badge.count > Self.maxBadgeLength { problems.append(.badBadge(badge)) }
    problems += (emails ?? []).filter { !Self.isEmail($0) }.map { .badEmail($0) }
    return problems
  }

  /// One `@`, no spaces, a dot in the domain.
  static func isEmail(_ text: String) -> Bool {
    text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
  }
}

public enum InstanceEditProblem: Sendable, Equatable {
  case emptyName
  case nameTooLong(Int)
  case badBadge(String)
  case badEmail(String)

  var message: String {
    switch self {
    case .emptyName: SupportText.string("draft.empty-name")
    case .nameTooLong(let count): SupportText.format("registry.name-too-long", count)
    case .badBadge: SupportText.string("registry.bad-badge")
    case .badEmail(let email): SupportText.format("registry.bad-email", email)
    }
  }

  var description: String {
    switch self {
    case .emptyName: "name is empty"
    case .nameTooLong(let count): "name is \(count) characters long (max 40)"
    case .badBadge(let badge): "badge \"\(badge)\" must be 1–6 characters"
    case .badEmail(let email): "invalid email \"\(email)\""
    }
  }
}

public enum InstanceEditError: Error, Equatable, Sendable {
  case notFound(String)
  /// The official app's entry is the base of the list and is never removed.
  case officialNotRemovable(String)
  case invalid([InstanceEditProblem])

  /// The user's text, in the UI language.
  public var message: String {
    switch self {
    case .notFound(let slug): SupportText.format("registry.not-found", slug)
    case .officialNotRemovable: SupportText.string("registry.official")
    case .invalid(let problems): problems.map(\.message).joined(separator: "; ")
    }
  }
}

extension InstanceEditError: CustomStringConvertible {
  /// English, for the CLI and logs.
  public var description: String {
    switch self {
    case .notFound(let slug): "no instance '\(slug)' in instances.json"
    case .officialNotRemovable(let slug): "'\(slug)' is the official app and cannot be removed from the list"
    case .invalid(let problems): "invalid edit: " + problems.map(\.description).joined(separator: "; ")
    }
  }
}

extension Instance {
  /// A copy with the edit applied (names trimmed); every other field stays.
  public func applying(_ edit: InstanceEdit) -> Instance {
    Instance(
      slug: slug, name: edit.name?.trimmingCharacters(in: .whitespaces) ?? name, kind: kind, bundleId: bundleId,
      appPath: appPath, profileDir: profileDir, accountUuid: accountUuid, orgUuid: orgUuid, emails: edit.emails ?? emails,
      cliConfigDir: cliConfigDir, badge: edit.badge ?? badge, builtBy: builtBy, pendingBuild: pendingBuild)
  }

  /// What removing the entry leaves in place: the app, its profile and its CLI folder that exist.
  public func leftOnDisk(paths: Paths) -> [String] {
    let cli = cliConfigDir ?? (kind == .official ? nil : paths.cliAccountsRoot.appendingPathComponent(slug.raw).path)
    return [appPath, profileDir, cli].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0) }
  }
}

extension InstanceStore {
  /// Applies `edit` to the entry in place and returns it; invalid edits change nothing.
  public func edit(slug: Slug, _ edit: InstanceEdit) throws -> Instance {
    let problems = edit.problems()
    guard problems.isEmpty else { throw InstanceEditError.invalid(problems) }
    let current = try loadOrSeed()
    guard let instance = current.first(where: { $0.slug == slug }) else { throw InstanceEditError.notFound(slug.raw) }
    let edited = instance.applying(edit)
    try save(current.map { $0.slug == slug ? edited : $0 })
    return edited
  }

  /// Removes the entry from the list only (apps, profiles and folders stay); refuses the official app.
  public func removeEntry(slug: Slug) throws -> Instance {
    let current = try loadOrSeed()
    guard let instance = current.first(where: { $0.slug == slug }) else { throw InstanceEditError.notFound(slug.raw) }
    guard instance.kind != .official else { throw InstanceEditError.officialNotRemovable(slug.raw) }
    try save(current.filter { $0.slug != slug })
    return instance
  }
}
