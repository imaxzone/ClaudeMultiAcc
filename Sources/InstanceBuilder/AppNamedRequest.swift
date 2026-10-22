import Foundation
import Support

/// The «Добавить» window names the app exactly as typed («Claude mv2»); the slug behind it is hidden, derived once
/// from that name and never changed afterwards (bundle id `com.imaxzone.claude.<slug>`, profile `ClaudeProfiles/<slug>`).
extension NewInstanceRequest {
  /// The request for a new app called `name` with `badge` on its icon (both trimmed), with a fresh hidden slug.
  public static func app(named name: String, badge: String, existing: [Instance], home: URL) -> NewInstanceRequest {
    let draft = InstanceDraft(name: name, badge: badge)
    return NewInstanceRequest(
      displayName: draft.name, slug: slug(forAppName: draft.name, existing: existing, home: home), badge: draft.badge)
  }

  /// "Claude mv2" → "mv2", "Работа" → "rabota", "🚀" → "app"; "-2", "-3", … while an instance already uses the
  /// slug, its bundle id or its profile folder. Always a valid slug.
  public static func slug(forAppName name: String, existing: [Instance], home: URL) -> String {
    let derived = slug(fromName: shortName(name))
    let base = derived.isEmpty ? "app" : derived
    var candidate = base
    var number = 1
    while isTaken(candidate, existing: existing, home: home) {
      number += 1
      let suffix = "-\(number)"
      let stem = String(base.prefix(32 - suffix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
      candidate = stem + suffix
    }
    return candidate
  }

  /// The icon label offered while the user has not typed one: the short name when it has at most four characters,
  /// else its first three.
  public static func suggestedBadge(forAppName name: String) -> String {
    let short = shortName(name)
    let label = short.count <= InstanceDraft.maxBadgeLength ? Substring(short) : short.prefix(3)
    return label.trimmingCharacters(in: .whitespaces)
  }

  /// The name without a leading "Claude" followed by a space, dash or underscore (any letter case).
  static func shortName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let range = trimmed.range(of: #"^claude[\s_-]+"#, options: [.regularExpression, .caseInsensitive]) else {
      return trimmed
    }
    return String(trimmed[range.upperBound...])
  }

  private static func isTaken(_ candidate: String, existing: [Instance], home: URL) -> Bool {
    guard let slug = try? Slug(candidate) else { return true }
    let spec = CloneSpec.newClone(slug: slug, displayName: "x", home: home)
    let profile = spec.profileDir.standardizedFileURL.path
    return existing.contains { instance in
      instance.slug == slug || instance.bundleId?.lowercased() == spec.bundleId
        || instance.profileDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == profile
    }
  }
}

public enum LeftoverProfileError: Error, Equatable, Sendable {
  /// The folder is missing, not a real folder, or an instance uses it.
  case notLeftover(String)
}

/// A profile folder `~/Library/Application Support/ClaudeProfiles/<slug>` that an app removed earlier left on disk
/// and no instance uses: a new app with that slug can sign in as before, or start clean (the folder goes to the Trash).
public enum LeftoverProfile {
  /// The folder when it is a real directory (not a link) that no instance uses; nil otherwise.
  public static func find(slug: String, existing: [Instance], home: URL) -> URL? {
    guard let valid = try? Slug(slug) else { return nil }
    let folder = CloneSpec.newClone(slug: valid, displayName: "x", home: home).profileDir
    var info = stat()
    guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
    let path = folder.standardizedFileURL.path
    let used = existing.contains { $0.profileDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path }
    return used ? nil : folder
  }

  /// "Начать с чистого": moves the leftover folder of `slug` to the Trash; refuses anything that is not a leftover.
  public static func trash(slug: String, existing: [Instance], home: URL, trash: any EditInstance.Trashing) async throws {
    guard let folder = find(slug: slug, existing: existing, home: home) else {
      throw LeftoverProfileError.notLeftover(slug)
    }
    try await trash.trash(folder)
  }
}
