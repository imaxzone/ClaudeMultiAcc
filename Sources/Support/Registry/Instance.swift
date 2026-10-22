import Foundation

/// How an instance is provided: the vendor app, a signed clone, or a CLI-only account without an app.
public enum InstanceKind: String, Codable, Sendable {
  case official
  case clone
  case cliOnly
}

/// One account/instance in `instances.json`. The list order is the display order everywhere (G20).
public struct Instance: Codable, Sendable, Equatable, Identifiable {
  public let slug: Slug
  public let name: String
  public let kind: InstanceKind
  public let bundleId: String?
  public let appPath: String?
  public let profileDir: String?
  public let accountUuid: String?
  public let orgUuid: String?
  public let emails: [String]
  public let cliConfigDir: String?
  public let badge: String?
  public let builtBy: String?
  public let pendingBuild: String?

  public var id: String { slug.raw }

  public init(
    slug: Slug, name: String, kind: InstanceKind, bundleId: String? = nil, appPath: String? = nil,
    profileDir: String? = nil, accountUuid: String? = nil, orgUuid: String? = nil, emails: [String] = [],
    cliConfigDir: String? = nil, badge: String? = nil, builtBy: String? = nil,
    pendingBuild: String? = nil
  ) {
    self.slug = slug
    self.name = name
    self.kind = kind
    self.bundleId = bundleId
    self.appPath = appPath
    self.profileDir = profileDir
    self.accountUuid = accountUuid
    self.orgUuid = orgUuid
    self.emails = emails
    self.cliConfigDir = cliConfigDir
    self.badge = badge
    self.builtBy = builtBy
    self.pendingBuild = pendingBuild
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      slug: try c.decode(Slug.self, forKey: .slug),
      name: try c.decode(String.self, forKey: .name),
      kind: try c.decode(InstanceKind.self, forKey: .kind),
      bundleId: try c.decodeIfPresent(String.self, forKey: .bundleId),
      appPath: try c.decodeIfPresent(String.self, forKey: .appPath),
      profileDir: try c.decodeIfPresent(String.self, forKey: .profileDir),
      accountUuid: try c.decodeIfPresent(String.self, forKey: .accountUuid),
      orgUuid: try c.decodeIfPresent(String.self, forKey: .orgUuid),
      emails: try c.decodeIfPresent([String].self, forKey: .emails) ?? [],
      cliConfigDir: try c.decodeIfPresent(String.self, forKey: .cliConfigDir),
      badge: try c.decodeIfPresent(String.self, forKey: .badge),
      builtBy: try c.decodeIfPresent(String.self, forKey: .builtBy),
      pendingBuild: try c.decodeIfPresent(String.self, forKey: .pendingBuild))
  }

  /// Writes every key, with explicit `null`s, so the file always shows the full schema. Keys of retired features
  /// (`rcDirs`) are ignored on read and dropped on the next write.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(slug, forKey: .slug)
    try c.encode(name, forKey: .name)
    try c.encode(kind, forKey: .kind)
    try c.encode(bundleId, forKey: .bundleId)
    try c.encode(appPath, forKey: .appPath)
    try c.encode(profileDir, forKey: .profileDir)
    try c.encode(accountUuid, forKey: .accountUuid)
    try c.encode(orgUuid, forKey: .orgUuid)
    try c.encode(emails, forKey: .emails)
    try c.encode(cliConfigDir, forKey: .cliConfigDir)
    try c.encode(badge, forKey: .badge)
    try c.encode(builtBy, forKey: .builtBy)
    try c.encode(pendingBuild, forKey: .pendingBuild)
  }

  private enum CodingKeys: String, CodingKey {
    case slug, name, kind, bundleId, appPath, profileDir, accountUuid, orgUuid, emails, cliConfigDir, badge
    case builtBy, pendingBuild
  }
}
