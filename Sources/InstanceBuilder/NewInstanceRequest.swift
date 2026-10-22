import Foundation
import IconRenderer
import Support

/// What the «Добавить» window (and `cmacc instance new`) asks for (R16, G20).
public struct NewInstanceRequest: Sendable, Equatable {
  public static let maxNameLength = 40

  public let name: String
  public let slug: String
  public let badge: String?
  public let emails: [String]
  /// The app's name in the Dock and Finder, and its file name `<displayName>.app`.
  public let displayName: String

  /// `cmacc instance new`: the app is called "Claude <name>".
  public init(name: String, slug: String, badge: String?, emails: [String]) {
    self.name = name
    self.slug = slug
    self.badge = badge
    self.emails = emails
    displayName = "Claude \(name)"
  }

  /// The «Добавить» window: the app is called exactly `displayName`.
  public init(displayName: String, slug: String, badge: String?, emails: [String] = []) {
    name = displayName
    self.slug = slug
    self.badge = badge
    self.emails = emails
    self.displayName = displayName
  }

  /// Fills the blanks: slug from the name (ASCII transliteration, `-`), badge = the whole name when it is at most
  /// five characters, else its first three; emails from a comma-separated list.
  public static func derive(name: String, slug: String? = nil, badge: String? = nil, emails: String = "") -> NewInstanceRequest {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let derivedBadge = String(trimmed.count <= 5 ? Substring(trimmed) : trimmed.prefix(3)).trimmingCharacters(in: .whitespaces)
    return NewInstanceRequest(
      name: trimmed, slug: slug ?? Self.slug(fromName: trimmed), badge: badge ?? derivedBadge, emails: parseEmails(emails))
  }

  /// `"Работа"` → `"rabota"`, `"My Team 2"` → `"my-team-2"`; at most 32 characters.
  public static func slug(fromName name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
    let plain = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
    var slug = ""
    for scalar in plain.unicodeScalars {
      if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
        slug.unicodeScalars.append(scalar)
      } else if !slug.isEmpty, !slug.hasSuffix("-") {
        slug.append("-")
      }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    return String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  public static func parseEmails(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  public func target(applicationsDir: URL) -> URL {
    applicationsDir.appendingPathComponent("\(displayName).app", isDirectory: true)
  }

  /// `CloneSpec.newClone` with display name "Claude <name>" and the badge. Call only with a valid slug.
  public func spec(home: URL) -> CloneSpec {
    let slugValue = (try? Slug(slug)) ?? (try? Slug("invalid"))
    guard let slugValue else { preconditionFailure("'invalid' is a valid slug") }
    return CloneSpec.newClone(slug: slugValue, displayName: displayName, home: home).with(badge: badge)
  }

  /// Every problem, in field order: name, slug (format, then uniqueness), badge, emails, target app.
  public func validate(
    against existing: [Instance], applicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [NewInstanceError] {
    let profileDir = (try? Slug(slug)).map { _ in spec(home: home).profileDir.path }
    return validate(against: existing, applicationsDir: applicationsDir, profileDir: profileDir)
  }

  /// Like `validate(against:applicationsDir:home:)` with the profile dir given directly (from a staged build).
  func validate(against existing: [Instance], applicationsDir: URL, profileDir: String?) -> [NewInstanceError] {
    var errors = nameErrors()
    if let profileDir, (try? Slug(slug)) != nil {
      errors += uniquenessErrors(existing, applicationsDir: applicationsDir, profileDir: profileDir)
    } else {
      errors.append(.badSlug(slug))
    }
    if let badge, badge.isEmpty || badge.count > BadgeStyle.maxLabelLength { errors.append(.badBadge(badge)) }
    errors += emails.filter { !Self.isEmail($0) }.map { .badEmail($0) }
    let target = target(applicationsDir: applicationsDir)
    if nameErrors().isEmpty, FileManager.default.fileExists(atPath: target.path) { errors.append(.targetExists(target.path)) }
    return errors
  }

  private func nameErrors() -> [NewInstanceError] {
    if name.trimmingCharacters(in: .whitespaces).isEmpty { return [.emptyName] }
    if name.count > Self.maxNameLength { return [.nameTooLong(name.count)] }
    if (try? CloneSpec.checkDisplayName(displayName)) == nil { return [.invalidName(name)] }
    return []
  }

  private func uniquenessErrors(_ existing: [Instance], applicationsDir: URL, profileDir: String) -> [NewInstanceError] {
    let bundleId = "com.imaxzone.claude.\(slug)"
    let appPath = target(applicationsDir: applicationsDir).path
    var errors: [NewInstanceError] = []
    // A taken slug implies its bundle id and profile: one message instead of three (P7).
    let slugTaken = existing.contains(where: { $0.slug.raw == slug })
    if slugTaken { errors.append(.duplicateSlug(slug)) }
    if !slugTaken, existing.contains(where: { $0.bundleId?.lowercased() == bundleId }) {
      errors.append(.duplicateBundleId(bundleId))
    }
    if existing.contains(where: { $0.appPath.map(Self.standardized) == appPath }) { errors.append(.duplicateAppPath(appPath)) }
    if !slugTaken, existing.contains(where: { $0.profileDir.map(Self.standardized) == Self.standardized(profileDir) }) {
      errors.append(.duplicateProfileDir(profileDir))
    }
    return errors
  }

  private static func standardized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  /// RFC-lite: one `@`, no spaces, a dot in the domain.
  static func isEmail(_ text: String) -> Bool {
    text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
  }
}
