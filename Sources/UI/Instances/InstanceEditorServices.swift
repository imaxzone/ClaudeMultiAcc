import AppKit
import InstanceBuilder
import Support

/// What the «Изменить…» / «Добавить» window needs from the machine. «Добавить» reuses the new-instance flow
/// (`NewInstanceServices`: validation, staging build, confirmed install); the rest is the edit engine and checks.
public protocol InstanceEditorServices: NewInstanceServices {
  /// The request for a new app called exactly `name`, with its hidden slug made unique against `existing`.
  func newRequest(name: String, badge: String, existing: [Instance]) -> NewInstanceRequest
  func isRunning(_ instance: Instance) async -> Bool
  func appExists(_ app: URL) -> Bool
  /// A profile folder for `slug` that a removed app left behind and no instance uses.
  func leftoverProfile(slug: String, existing: [Instance]) -> URL?
  /// Moves that folder to the Trash («Начать с чистого»).
  func trashLeftoverProfile(slug: String, existing: [Instance]) async throws
  func open(app: URL) async throws
  func edit(
    _ change: InstanceChange, identity: SigningIdentity, progress: @escaping @Sendable (EditStage) async -> Void
  ) async throws -> EditOutcome
}

/// What «Добавить» does with a profile a removed app of the same name left behind (asked in the window).
public enum LeftoverProfileChoice: Hashable, Sendable {
  /// The new app uses the folder as it is: it opens signed in, with the old settings.
  case signInAsBefore
  /// The folder goes to the Trash right before the install.
  case startClean
}

/// The question the window asks once the build is verified (`NSAlert` in the app).
@MainActor
public protocol InstanceEditorDialogs: AnyObject {
  func confirmInstall(request: NewInstanceRequest, report: BuildReport) async -> Bool
}

/// The real machine: the new-instance services for «Добавить», `EditInstance.live` for «Изменить…».
/// `quitter` / `opener` close and reopen a running clone around «Сохранить» (default: polite NSRunningApplication quit,
/// NSWorkspace open in the background).
public struct LiveInstanceEditorServices: InstanceEditorServices {
  private let base: LiveNewInstanceServices
  private let paths: Paths
  private let runner: ProcessRunning
  private let launcherBinary: URL
  private let quitter: (any AppQuitting)?
  private let opener: (any AppOpening)?

  public init(
    paths: Paths, launcherBinary: URL, runner: ProcessRunning = SystemProcessRunner(),
    applicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true), quitter: (any AppQuitting)? = nil,
    opener: (any AppOpening)? = nil
  ) {
    base = LiveNewInstanceServices(paths: paths, launcherBinary: launcherBinary, runner: runner, applicationsDir: applicationsDir)
    self.paths = paths
    self.runner = runner
    self.launcherBinary = launcherBinary
    self.quitter = quitter
    self.opener = opener
  }

  public func existingInstances() async throws -> [Instance] { try await base.existingInstances() }

  public func validate(_ request: NewInstanceRequest, existing: [Instance]) -> [NewInstanceError] {
    base.validate(request, existing: existing)
  }

  public func permanentIdentity() async -> SigningIdentity? { await base.permanentIdentity() }

  public func build(_ request: NewInstanceRequest, identity: SigningIdentity) async throws -> BuildReport {
    try await base.build(request, identity: identity)
  }

  public func discard(slug: String) async throws { try await base.discard(slug: slug) }

  public func install(staged: URL, request: NewInstanceRequest, report: BuildReport) async throws -> Instance {
    try await base.install(staged: staged, request: request, report: report)
  }

  public func newRequest(name: String, badge: String, existing: [Instance]) -> NewInstanceRequest {
    NewInstanceRequest.app(named: name, badge: badge, existing: existing, home: paths.home)
  }

  public func isRunning(_ instance: Instance) async -> Bool {
    guard let bundleId = instance.bundleId else { return false }
    let profile = instance.profileDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
    return await RunningCheck(runner: runner).isRunning(bundleId: bundleId, profileDir: profile)
  }

  public func appExists(_ app: URL) -> Bool { FileManager.default.fileExists(atPath: app.path) }

  public func leftoverProfile(slug: String, existing: [Instance]) -> URL? {
    LeftoverProfile.find(slug: slug, existing: existing, home: paths.home)
  }

  public func trashLeftoverProfile(slug: String, existing: [Instance]) async throws {
    try await LeftoverProfile.trash(slug: slug, existing: existing, home: paths.home, trash: WorkspaceTrash())
  }

  public func open(app: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
  }

  public func edit(
    _ change: InstanceChange, identity: SigningIdentity, progress: @escaping @Sendable (EditStage) async -> Void
  ) async throws -> EditOutcome {
    try paths.ensureDataDirs()
    let engine = EditInstance.live(
      paths: paths, runner: runner, launcherBinary: launcherBinary, quitter: quitter, opener: opener)
    return try await engine.apply(change, identity: identity, progress: progress)
  }
}

/// No permanent signing identity, and `ensureSigning` could not provide one.
public enum InstanceEditorSigningError: Error, Equatable, Sendable {
  case unavailable
}

/// The `ensureSigning` used until a provisioner is wired in: today's read-only identity check.
public enum InstanceEditorSigning {
  public static func identityCheck(
    paths: Paths, runner: ProcessRunning = SystemProcessRunner()
  ) -> @Sendable () async throws -> SigningIdentity {
    {
      guard let identity = await SigningIdentityCheck(paths: paths, runner: runner).permanentIdentity() else {
        throw InstanceEditorSigningError.unavailable
      }
      return identity
    }
  }
}

/// The install confirmation as an `NSAlert`.
@MainActor
public final class AlertInstanceEditorDialogs: InstanceEditorDialogs {
  public init() {}

  public func confirmInstall(request: NewInstanceRequest, report: BuildReport) async -> Bool {
    let alert = NSAlert()
    alert.messageText = InstanceEditorText.installTitle(name: request.displayName)
    alert.informativeText = InstanceEditorText.installText
    alert.addButton(withTitle: InstanceEditorText.install)
    alert.addButton(withTitle: InstanceEditorText.cancel)
    return await ModalAlert.run(alert) == .alertFirstButtonReturn
  }
}
