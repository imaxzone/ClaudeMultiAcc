import Foundation
import Support

/// What to build: one clone of Claude Desktop with its own bundle id, display name and profile (G11, G20).
public struct CloneSpec: Sendable, Equatable {
  public static let vendorBundleId = "com.anthropic.claudefordesktop"
  public static let legacySecondBundleId = "com.anthropic.claudefordesktop2"

  public let slug: Slug
  public let displayName: String
  public let bundleId: String
  public let profileDir: URL
  public let badge: String?

  public init(slug: Slug, displayName: String, bundleId: String, profileDir: URL, badge: String?) {
    self.slug = slug
    self.displayName = displayName
    self.bundleId = bundleId
    self.profileDir = profileDir
    self.badge = badge
  }

  /// A new clone: `com.imaxzone.claude.<slug>`, profile `~/Library/Application Support/ClaudeProfiles/<slug>`.
  public static func newClone(slug: Slug, displayName: String, home: URL) -> CloneSpec {
    CloneSpec(
      slug: slug, displayName: displayName, bundleId: "com.imaxzone.claude.\(slug.raw)",
      profileDir: profilesRoot(home: home).appendingPathComponent(slug.raw, isDirectory: true),
      badge: nil)
  }

  /// The legacy "Claude 2nd" clone (Step-6 allowance; the only permitted `com.anthropic.*` id).
  public static func second(home: URL) -> CloneSpec {
    CloneSpec(
      slug: legacySecondSlug, displayName: "Claude 2nd", bundleId: legacySecondBundleId,
      profileDir: profilesRoot(home: home).appendingPathComponent("second", isDirectory: true),
      badge: "2nd")
  }

  /// The spec of any clone registered in `instances.json`; official and CLI-only instances are refused.
  public static func from(instance: Instance) throws -> CloneSpec {
    guard instance.kind == .clone else { throw BuilderError.notAClone(instance.slug.raw) }
    guard let bundleId = instance.bundleId, let profileDir = instance.profileDir else {
      throw BuilderError.incompleteInstance(instance.slug.raw)
    }
    try checkBundleId(bundleId, slug: instance.slug)
    return CloneSpec(
      slug: instance.slug, displayName: instance.name, bundleId: bundleId,
      profileDir: URL(fileURLWithPath: profileDir, isDirectory: true), badge: instance.badge)
  }

  public func with(badge: String?) -> CloneSpec {
    CloneSpec(slug: slug, displayName: displayName, bundleId: bundleId, profileDir: profileDir, badge: badge)
  }

  public func with(profileDir: URL) -> CloneSpec {
    CloneSpec(slug: slug, displayName: displayName, bundleId: bundleId, profileDir: profileDir, badge: badge)
  }

  /// Throws `.vendorBundleId` for any id in the `com.anthropic.` namespace (compared case-insensitively, as
  /// LaunchServices does), except exactly the legacy `com.anthropic.claudefordesktop2` on slug `second`.
  public static func checkBundleId(_ bundleId: String, slug: Slug) throws {
    let lowered = bundleId.lowercased()
    guard lowered.hasPrefix(anthropicNamespace) else { return }
    if lowered == legacySecondBundleId, slug == legacySecondSlug { return }
    throw BuilderError.vendorBundleId(bundleId)
  }

  static let anthropicNamespace = "com.anthropic."

  /// Display names become file names (`<name>.app`): non-empty, no `/` or `:`, no leading dot, no surrounding spaces,
  /// no control characters, ≤ 64 characters. Every build checks it, so CLI and registry names are held to it too.
  public static func checkDisplayName(_ name: String) throws {
    let invalid = name.isEmpty || name.count > 64 || name.hasPrefix(".") || name.contains("/") || name.contains(":")
      || name.trimmingCharacters(in: .whitespaces) != name || hasControlCharacters(name)
    if invalid { throw BuilderError.invalidDisplayName(name) }
  }

  /// The add window's rule (`InstanceDraft.hasControlCharacters`): control characters (NUL, tab, newline, escape…),
  /// line and paragraph separators and the invisible direction marks and overrides that can disguise a file name.
  /// Zero-width joiners inside emoji stay allowed.
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

  private static let legacySecondSlug: Slug = {
    guard let slug = try? Slug("second") else { preconditionFailure("'second' is a valid slug") }
    return slug
  }()

  /// `~/Library/Application Support/ClaudeProfiles`: every clone's profile is `<root>/<slug>`.
  static func profilesRoot(home: URL) -> URL {
    home.appendingPathComponent("Library/Application Support/ClaudeProfiles", isDirectory: true)
  }
}

extension CloneSpec {
  /// Older reports also carry `neutralizeUpdater`; it is ignored (the updater step was retired, see
  /// `VendorFrameworksCheck`).
  private struct ReportFlags: Decodable {
    let badge: String?
  }

  /// Reconstructs the spec of a staged clone from its patched Info.plist and launcher config; the badge comes from
  /// the sibling `build-report.json` when present (no badge otherwise).
  public static func fromStagedApp(_ app: URL) throws -> CloneSpec {
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL) else { throw BuilderError.invalidPlist("missing \(infoURL.path)") }
    let info = try PlistPatcher.decode(data)
    guard let rawSlug = info[PlistPatcher.slugKey] as? String, let slug = try? Slug(rawSlug),
          let bundleId = info["CFBundleIdentifier"] as? String, let display = info["CFBundleDisplayName"] as? String
    else { throw BuilderError.invalidPlist("not a ClaudeMultiAcc clone: \(app.path)") }
    let configURL = app.appendingPathComponent("Contents/Resources/\(LauncherConfigFile.fileName)")
    guard let configData = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode(LauncherConfigFile.self, from: configData)
    else { throw BuilderError.launcherMissing(configURL.path) }
    let reportURL = app.deletingLastPathComponent().appendingPathComponent("build-report.json")
    let flags = (try? Data(contentsOf: reportURL)).flatMap { try? JSONDecoder().decode(ReportFlags.self, from: $0) }
    return CloneSpec(
      slug: slug, displayName: display, bundleId: bundleId,
      profileDir: URL(fileURLWithPath: config.profileDir, isDirectory: true), badge: flags?.badge)
  }
}
