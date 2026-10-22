import AppKit
import IconRenderer
import InstanceBuilder
import Support

/// What «Добавить» needs from the machine to make a new app: validation, a staging build, a confirmed install
/// (`InstanceEditorServices` adds the rest); `LiveNewInstanceServices` in the app, fakes in tests.
public protocol NewInstanceServices: Sendable {
  func existingInstances() async throws -> [Instance]
  func validate(_ request: NewInstanceRequest, existing: [Instance]) -> [NewInstanceError]
  func permanentIdentity() async -> SigningIdentity?
  func build(_ request: NewInstanceRequest, identity: SigningIdentity) async throws -> BuildReport
  func discard(slug: String) async throws
  func install(staged: URL, request: NewInstanceRequest, report: BuildReport) async throws -> Instance
}

/// The new-app services on the real machine: staging builds only until the user confirms an install.
public struct LiveNewInstanceServices: NewInstanceServices {
  private let paths: Paths
  private let runner: ProcessRunning
  private let applicationsDir: URL
  private let launcherBinary: URL

  public init(paths: Paths, launcherBinary: URL, runner: ProcessRunning = SystemProcessRunner(),
              applicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) {
    self.paths = paths
    self.runner = runner
    self.applicationsDir = applicationsDir
    self.launcherBinary = launcherBinary
  }

  public func existingInstances() async throws -> [Instance] {
    try await InstanceStore(paths: paths).load()
  }

  public func validate(_ request: NewInstanceRequest, existing: [Instance]) -> [NewInstanceError] {
    request.validate(against: existing, applicationsDir: applicationsDir, home: paths.home)
  }

  public func permanentIdentity() async -> SigningIdentity? {
    await SigningIdentityCheck(paths: paths, runner: runner).permanentIdentity()
  }

  public func build(_ request: NewInstanceRequest, identity: SigningIdentity) async throws -> BuildReport {
    try paths.ensureDataDirs()
    let spec = request.spec(home: paths.home)
    let pipeline = InstanceBuildPipeline(paths: paths, runner: runner, launcherBinary: launcherBinary, clock: SystemClock())
    return try await pipeline.build(
      spec: spec, source: applicationsDir.appendingPathComponent("Claude.app", isDirectory: true), identity: identity,
      intent: .stagingOnly)
  }

  public func discard(slug: String) async throws {
    _ = try StagingArea(paths: paths).discard(slug: try Slug(slug))
  }

  public func install(staged: URL, request: NewInstanceRequest, report: BuildReport) async throws -> Instance {
    let installer = InstallNewInstance(
      applicationsDir: applicationsDir, store: InstanceStore(paths: paths),
      registrar: Registrar(runner: runner, staging: StagingArea(paths: paths)), running: RunningCheck(runner: runner))
    return try await installer.install(staged: staged, request: request, report: report)
  }
}

/// The badged icon preview: the official `electron.icns` read as a file (never an icon query, never a staged
/// bundle) with the badge composited on top.
@MainActor
enum BadgePreview {
  /// The official icon file; tests point it elsewhere to stay hermetic.
  static var source = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources/electron.icns")
  private static var cache: (path: String, image: CGImage?)?

  static func image(label: String) -> NSImage? {
    if cache?.path != source.path {
      var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
      cache = (source.path, NSImage(contentsOf: source)?.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }
    guard let base = cache?.image else { return nil }
    let composed = label.isEmpty ? base : ((try? BadgeCompositor.compose(base: base, style: .standard(label: label))) ?? base)
    return NSImage(cgImage: composed, size: NSSize(width: 1024, height: 1024))
  }
}
