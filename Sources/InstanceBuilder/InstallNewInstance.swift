import Foundation
import os
import Support

public enum InstallError: Error, Equatable, Sendable {
  case notVerified
  case reportMismatch
  case invalid([NewInstanceError])
  case running(String)
  case launcherConfigMissing(String)
  case differentVolumes
  /// Ad hoc builds are test builds only ("только проверка").
  case adhocBuild
  case noPermanentIdentity
  /// Registering or recording the moved app failed; it was moved back to `restoredTo` (staging).
  case afterMove(step: String, message: String, restoredTo: String)
  /// That move back failed too; the app is still at `leftAt`.
  case compensationFailed(original: String, leftAt: String)
}

extension InstallError: CustomStringConvertible {
  /// English, for the CLI and logs.
  public var description: String {
    switch self {
    case .notVerified: "the build did not verify"
    case .reportMismatch: "the build report does not match the request"
    case .invalid(let errors): "invalid request: " + errors.map(\.description).joined(separator: "; ")
    case .running(let id): "\(id) is running"
    case .launcherConfigMissing(let path): "launcher config missing: \(path)"
    case .differentVolumes: "staging and /Applications are on different volumes"
    case .adhocBuild: "ad hoc builds are test builds only and cannot be installed"
    case .noPermanentIdentity: "--install needs the permanent signing identity (\(SigningSetup.hint), or pass --identity <sha1>)"
    case .afterMove(let step, let message, let restoredTo):
      "\(step) failed after the move (\(message)); the build was moved back to \(restoredTo)"
    case .compensationFailed(let original, let leftAt):
      "\(original); moving the build back to staging failed too — it is still at \(leftAt) and not in instances.json"
    }
  }
}

/// Installs a verified staged build as a new instance: moves it to `<applicationsDir>/Claude <name>.app`
/// (same volume only), registers it and appends it to `instances.json`. The badge is already in the build's
/// `electron.icns` (`BadgeStep`), so nothing is written into the installed bundle afterwards. Never creates the
/// profile dir (the launcher does on first start). Exercised only by hermetic tests in this project (G19).
public struct InstallNewInstance: Sendable {
  private let applicationsDir: URL
  private let store: InstanceStore
  private let registrar: any AppRegistering
  private let running: any RunningChecking
  private let mover: FileMover
  private let log = AppLog.logger("install-new-instance")

  public init(
    applicationsDir: URL, store: InstanceStore, registrar: any AppRegistering, running: any RunningChecking,
    mover: FileMover = .live
  ) {
    self.applicationsDir = applicationsDir
    self.store = store
    self.registrar = registrar
    self.running = running
    self.mover = mover
  }

  public func install(staged: URL, request: NewInstanceRequest, report: BuildReport) async throws -> Instance {
    guard report.verified else { throw InstallError.notVerified }
    guard report.identityKind != SigningIdentity.adhoc.kind else { throw InstallError.adhocBuild }
    guard report.slug == request.slug, report.displayName == request.displayName,
          URL(fileURLWithPath: report.stagedPath).standardizedFileURL == staged.standardizedFileURL
    else { throw InstallError.reportMismatch }
    let existing: [Instance]
    do {
      existing = try await store.load()
    } catch {
      throw InstallError.invalid([.storeCorrupt(String(describing: error))])
    }
    let profileDir = try launcherProfile(staged)
    let errors = request.validate(against: existing, applicationsDir: applicationsDir, profileDir: profileDir)
    guard errors.isEmpty else { throw InstallError.invalid(errors) }
    if await running.isRunning(bundleId: report.bundleId, profileDir: nil) { throw InstallError.running(report.bundleId) }
    guard Volume.same(staged, applicationsDir) else { throw InstallError.differentVolumes }

    let target = request.target(applicationsDir: applicationsDir)
    let instance = Instance(
      slug: try Slug(request.slug), name: request.displayName, kind: .clone, bundleId: report.bundleId,
      appPath: target.path, profileDir: profileDir, emails: request.emails, badge: request.badge, builtBy: "cmacc")
    try mover.move(staged, target)
    log.info("installed \(target.path, privacy: .public)")
    try await afterMove("register", target: target, staged: staged) { try await registrar.register(target) }
    try await afterMove("store", target: target, staged: staged) { _ = try await store.upsert(instance) }
    return instance
  }

  /// Runs a step after the move; on failure moves the app back to staging (never silently).
  private func afterMove(_ step: String, target: URL, staged: URL, _ body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch {
      let message = String(describing: error)
      log.error("\(step, privacy: .public) failed after installing: \(message, privacy: .public); moving the build back")
      do {
        try mover.move(target, staged)
      } catch let undo {
        log.error("cannot move \(target.path, privacy: .public) back: \(String(describing: undo), privacy: .public)")
        throw InstallError.compensationFailed(original: "\(step): \(message)", leftAt: target.path)
      }
      throw InstallError.afterMove(step: step, message: message, restoredTo: staged.path)
    }
  }

  /// The identity for an installable build: an explicit certificate or the permanent one, never ad hoc.
  public static func identity(explicit: SigningIdentity?, permanent: SigningIdentity?) throws -> SigningIdentity {
    guard let identity = explicit ?? permanent else { throw InstallError.noPermanentIdentity }
    guard identity != .adhoc else { throw InstallError.adhocBuild }
    return identity
  }

  /// The profile the staged launcher will use (the authoritative value from the build).
  private func launcherProfile(_ staged: URL) throws -> String {
    let url = staged.appendingPathComponent("Contents/Resources/\(LauncherConfigFile.fileName)")
    guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(LauncherConfigFile.self, from: data)
    else { throw InstallError.launcherConfigMissing(url.path) }
    return config.profileDir
  }
}
