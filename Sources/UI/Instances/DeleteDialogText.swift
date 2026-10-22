import Foundation
import InstanceBuilder
import Support

/// Every string of «Удалить «Claude mv2»?» for one clone. Sizes are «…» until they are known.
public struct DeleteDialogText: Equatable, Sendable {
  /// One choice: «Только приложение — 632 МБ» with what goes and what stays.
  public struct Option: Equatable, Sendable {
    public let label: String
    public let size: String
    public let removes: String
    public let keeps: String
    /// «Папка: ~/Library/…/mv2» under «Всё», so the user sees which folder goes too; nil elsewhere.
    public let detail: String?

    public var title: String { "\(label) — \(size)" }
  }

  public static var cancelButton: String { UIText.string("common.cancel") }
  public static var deleteButton: String { UIText.string("delete.delete") }
  /// Closes the problem alert (Cyrillic «ОК» in Russian, as macOS writes it).
  public static var okButton: String { UIText.string("delete.ok") }
  public static var refusedTitle: String { UIText.string("delete.refused-title") }
  static let pending = "…"

  public let title: String
  public let lead: String
  public let appOnly: Option
  public let everything: Option
  public let footer: String

  /// `appOnlyBytes` is the app with its old copies; `everything` adds `profileBytes` and names `profileDir`
  /// (abbreviated with `~` inside `home`).
  public init(
    name: String, app: URL, appOnlyBytes: Int64?, profileBytes: Int64?, hasOldCopies: Bool, profileReusable: Bool,
    profileDir: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    title = UIText.format("delete.title", name)
    lead = UIText.string("delete.lead")
    let folder = app.deletingLastPathComponent().standardizedFileURL.path
    let place = folder == "/Applications"
      ? UIText.string("delete.place.applications") : UIText.format("delete.place.folder", folder)
    let profile = profileBytes == 0 ? "" : UIText.format("delete.app-only.size", Self.size(profileBytes))
    let reuse = profileReusable ? UIText.string("delete.app-only.reuse") : ""
    appOnly = Option(
      label: UIText.string("delete.app-only.label"), size: Self.size(appOnlyBytes),
      removes: UIText.format("delete.app-only.removes", name, place)
        + (hasOldCopies ? UIText.string("delete.app-only.old-copies") : ""),
      keeps: UIText.format("delete.app-only.keeps", profile, reuse), detail: nil)
    let total = appOnlyBytes.flatMap { app in profileBytes.map { app + $0 } }
    everything = Option(
      label: UIText.string("delete.everything.label"), size: Self.size(total),
      removes: UIText.string("delete.everything.removes"),
      keeps: UIText.string("delete.everything.keeps"),
      detail: profileDir.map { UIText.format("delete.everything.folder", ClonePathPolicy.tilde($0, home: home)) })
    footer = UIText.string("delete.footer")
  }

  /// `632 МБ`, `12,6 ГБ`, `632 MB` (file sizes in the current locale); «…» while unknown.
  public static func size(_ bytes: Int64?) -> String {
    guard let bytes else { return pending }
    return Localization.byteCount(bytes)
  }

  /// The text for an open question, with the target's profile folder named under «Всё».
  @MainActor
  init(_ model: DeleteDialogModel, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.init(
      name: model.target.name, app: model.target.app, appOnlyBytes: model.appOnlyBytes, profileBytes: model.profileBytes,
      hasOldCopies: model.target.hasOldCopies, profileReusable: model.target.profileReusable,
      profileDir: model.target.profileDir, home: home)
  }

  /// The alert title after a removal with problems.
  public static func problemTitle(_ report: RemovalReport) -> String {
    UIText.format(report.changedNothing ? "delete.problem.nothing" : "delete.problem.partial", report.name)
  }
}
