import Foundation
import os
import Support

/// Registers an installed app with LaunchServices, and makes LaunchServices forget a bundle at a path.
public protocol AppRegistering: Sendable {
  func register(_ app: URL) async throws
  /// `lsregister -u`: LaunchServices forgets the bundle at `app` (a backup, a staged build, an old copy).
  func unregister(_ app: URL) async throws
}

/// `lsregister -f <app>` for installed bundles only; staged bundles are refused (G4, G12). Used by `rebuild --apply`,
/// `rollback`, the UpdateWatcher swap, the new-instance install and «Обновить Док». `unregister` (`lsregister -u`)
/// is allowed everywhere, backup and staging folders included: forgetting those bundles is its purpose.
public struct Registrar: AppRegistering {
  private let runner: ProcessRunning
  private let staging: StagingArea?
  private let log = AppLog.logger("registrar")

  public init(runner: ProcessRunning, staging: StagingArea?) {
    self.runner = runner
    self.staging = staging
  }

  public func register(_ app: URL) async throws {
    if let staging, staging.contains(app) { throw BuilderError.stagingPathRefused(app.path) }
    log.info("lsregister -f \(app.path, privacy: .public)")
    try await runner.runChecked(BuilderTool.lsregister, ["-f", app.path], timeout: BuilderTool.shortTimeout)
  }

  public func unregister(_ app: URL) async throws {
    try await LaunchServicesUnregistrar(runner: runner).unregister(app)
  }
}

extension AppRegistering {
  /// `unregister`, never throwing: a stale LaunchServices record must never fail a swap, so a failure only goes to
  /// `log` (updates.log) with `context`. True when LaunchServices forgot the bundle.
  @discardableResult
  func unregisterLogged(_ app: URL, context: String, log: RedactingFileLog) async -> Bool {
    do {
      try await unregister(app)
      return true
    } catch {
      await log.write("lsregister -u \(app.path) failed (\(context)): \(error)", category: "updates")
      return false
    }
  }
}
