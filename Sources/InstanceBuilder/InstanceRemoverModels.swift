import Foundation
import Support

/// What «Удалить «…»…» removes: the app only (its profile stays, so adding it again finds the sign-in) or everything
/// of this clone on the Mac.
public enum RemovalMode: String, Sendable, Equatable, CaseIterable {
  case appOnly
  case everything
}

/// One thing that goes to the Trash.
public struct RemovalItem: Sendable, Equatable {
  public enum Kind: String, Sendable, Equatable {
    /// The installed bundle.
    case app
    /// `<data>/backup/[legacy-]<App>.app.<stamp>`: an earlier build kept by an update.
    case backup
    /// `<data>/staging/<slug>-<stamp>.noindex`: a build waiting to be installed or left over.
    case staging
    /// The profile: sign-in, settings, cache and local files.
    case profile
  }

  public let kind: Kind
  public let url: URL

  public init(kind: Kind, url: URL) {
    self.kind = kind
    self.url = url
  }
}

/// A clone that may be removed, with everything of it found on disk.
public struct RemovalTarget: Sendable, Equatable {
  public let slug: Slug
  public let name: String
  public let bundleId: String
  public let app: URL
  public let profileDir: URL?
  /// Oldest name first (the stamp sorts lexicographically).
  public let backups: [URL]
  public let stagingBuilds: [URL]
  /// Adding a clone with the same name later uses this profile again (the standard place for its slug, and the
  /// name derives that slug), so the sign-in survives an app-only removal.
  public let profileReusable: Bool
  /// Every item as `InstanceRemover.target` found it (`ClonePathPolicy`), compared again right before it moves.
  let checked: [CheckedPath]

  public init(
    slug: Slug, name: String, bundleId: String, app: URL, profileDir: URL?, backups: [URL], stagingBuilds: [URL],
    profileReusable: Bool
  ) {
    self.init(
      slug: slug, name: name, bundleId: bundleId, app: app, profileDir: profileDir, backups: backups,
      stagingBuilds: stagingBuilds, profileReusable: profileReusable, checked: [])
  }

  init(
    slug: Slug, name: String, bundleId: String, app: URL, profileDir: URL?, backups: [URL], stagingBuilds: [URL],
    profileReusable: Bool, checked: [CheckedPath]
  ) {
    self.slug = slug
    self.name = name
    self.bundleId = bundleId
    self.app = app
    self.profileDir = profileDir
    self.backups = backups
    self.stagingBuilds = stagingBuilds
    self.profileReusable = profileReusable
    self.checked = checked
  }

  /// Backups or staging builds exist (they go with the app in both modes).
  public var hasOldCopies: Bool { !backups.isEmpty || !stagingBuilds.isEmpty }

  /// What goes to the Trash, the app first and the profile last.
  public func items(_ mode: RemovalMode) -> [RemovalItem] {
    let copies = backups.map { RemovalItem(kind: .backup, url: $0) }
      + stagingBuilds.map { RemovalItem(kind: .staging, url: $0) }
    let profile = mode == .everything ? profileDir.map { [RemovalItem(kind: .profile, url: $0)] } ?? [] : []
    return [RemovalItem(kind: .app, url: app)] + copies + profile
  }

  /// What `url` holds now compared with the check; an item that was never checked counts as changed.
  func state(of url: URL) -> CheckedPath.State {
    checked.first { $0.url == url }?.state() ?? .changed
  }
}

/// What one removal did. `problems` are the alert's lines (UI language); empty when everything went as asked.
public struct RemovalReport: Sendable, Equatable {
  public let slug: String
  public let name: String
  /// Original locations now in the Trash, in the order they were moved.
  public let trashed: [URL]
  /// Items that should have gone but stayed in place.
  public let notTrashed: [URL]
  public let recordRemoved: Bool
  public let problems: [String]

  public init(slug: String, name: String, trashed: [URL], notTrashed: [URL], recordRemoved: Bool, problems: [String]) {
    self.slug = slug
    self.name = name
    self.trashed = trashed
    self.notTrashed = notTrashed
    self.recordRemoved = recordRemoved
    self.problems = problems
  }

  /// Nothing was moved and the list is unchanged (refused or stopped before the first move).
  public var changedNothing: Bool { trashed.isEmpty && !recordRemoved }

  static func refused(slug: String, name: String, _ problem: String, notTrashed: [URL] = []) -> RemovalReport {
    RemovalReport(
      slug: slug, name: name, trashed: [], notTrashed: notTrashed, recordRemoved: false, problems: [problem])
  }
}

/// Why a removal cannot start. `userMessage` is in the UI language, `description` English (logs).
public enum RemovalError: Error, Equatable, Sendable {
  case notFound(String)
  case notAClone(name: String, kind: InstanceKind)
  /// The record has no app path or bundle id.
  case incomplete(String)
  /// `ClonePathPolicy` does not accept the app or profile the record names.
  case unsafePath(ClonePathRefusal)
  case storeUnreadable(String)

  public var userMessage: String {
    switch self {
    case .notFound(let slug): BuilderText.format("remove.not-found", slug)
    case .notAClone(_, .official): BuilderText.string("remove.official")
    case .notAClone(let name, _): BuilderText.format("remove.no-app", name)
    case .incomplete(let name): BuilderText.format("remove.incomplete", name)
    case .unsafePath(let refusal): refusal.userMessage
    case .storeUnreadable: BuilderText.string("store.unreadable")
    }
  }
}

extension RemovalError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .notFound(let slug): "no instance '\(slug)' in instances.json"
    case .notAClone(let name, let kind): "'\(name)' is \(kind.rawValue), only clones are removed"
    case .incomplete(let name): "'\(name)' has no app path or bundle id"
    case .unsafePath(let refusal): "refused by the path policy: \(refusal)"
    case .storeUnreadable(let detail): "cannot read instances.json: \(detail)"
    }
  }
}
