import Foundation
import os
import Support

extension InstanceStore: EditInstance.Store {}

/// `BundleSwapper.swap` into the backup folder, stamped with `clock`.
public struct BundleSwap: EditInstance.Swapping {
  private let backupDir: URL
  private let clock: any Support.Clock
  private let timeZone: TimeZone
  private let mover: FileMover

  public init(backupDir: URL, clock: any Support.Clock = SystemClock(), timeZone: TimeZone = .current, mover: FileMover = .live) {
    self.backupDir = backupDir
    self.clock = clock
    self.timeZone = timeZone
    self.mover = mover
  }

  public func swap(live: URL, staged: URL, expectedLive: FileIdentity) async throws -> URL {
    try BundleSwapper.swap(
      live: live, staged: staged, backupDir: backupDir, now: clock.now, timeZone: timeZone, mover: mover,
      expectedLive: expectedLive)
  }
}

/// `lsregister -u <app>`: forgets the bundle at that path in LaunchServices (so an old copy or one in the Trash is no
/// longer offered for `claude://` links). With `staging`, staged bundles are refused like `Registrar` refuses them.
public struct LaunchServicesUnregistrar: EditInstance.Unregistering, AppUnregistering {
  private let runner: ProcessRunning
  private let staging: StagingArea?

  public init(runner: ProcessRunning, staging: StagingArea? = nil) {
    self.runner = runner
    self.staging = staging
  }

  public func unregister(_ app: URL) async throws {
    if let staging, staging.contains(app) { throw BuilderError.stagingPathRefused(app.path) }
    AppLog.logger("registrar").info("lsregister -u \(app.path, privacy: .public)")
    try await runner.runChecked(BuilderTool.lsregister, ["-u", app.path], timeout: BuilderTool.shortTimeout)
  }
}

/// `FileManager.trashItem`: the item lands in the user's Trash and can be put back from there.
public struct WorkspaceTrash: EditInstance.Trashing {
  public init() {}

  public func trash(_ item: URL) async throws {
    try FileManager.default.trashItem(at: item, resultingItemURL: nil)
    AppLog.logger("edit-instance").info("moved \(item.path, privacy: .public) to the Trash")
  }
}

extension EditInstance {
  /// The real machine: the builder pipeline from the newest Claude (`ClaudeSourceStore`),
  /// NSRunningApplication/lsappinfo/lock checks, polite quit and NSWorkspace reopen (unless `quitter` / `opener` are
  /// given), `lsregister`, the Trash and backups in `<data>/backup`.
  public static func live(
    paths: Paths, runner: ProcessRunning, launcherBinary: URL, quitter: (any AppQuitting)? = nil,
    opener: (any AppOpening)? = nil
  ) -> EditInstance {
    let staging = StagingArea(paths: paths)
    let effects = Effects(
      store: InstanceStore(paths: paths),
      builder: InstanceBuildPipeline(paths: paths, runner: runner, launcherBinary: launcherBinary, clock: SystemClock()),
      running: RunningCheck(runner: runner), quitter: quitter ?? WorkspaceQuitter(), opener: opener ?? WorkspaceOpener(),
      registrar: Registrar(runner: runner, staging: staging),
      unregistrar: LaunchServicesUnregistrar(runner: runner, staging: staging), trash: WorkspaceTrash(),
      swapper: BundleSwap(backupDir: paths.backupDir))
    return EditInstance(paths: paths, effects: effects)
  }
}
