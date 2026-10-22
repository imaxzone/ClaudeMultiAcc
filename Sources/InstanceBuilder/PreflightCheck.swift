import Foundation
import Support

/// One line of `cmacc instance rebuild second --check`: `PASS|FAIL id — detail`.
public struct PreflightItem: Codable, Sendable, Equatable {
  public static let updateLock = "update-lock"
  public static let notRunning = "not-running"
  public static let notHostedInside = "not-hosted-inside"
  public static let identityPresent = "identity-present"
  public static let diskSpace = "disk-space"
  public static let vendorIdle = "vendor-idle"
  public static let sourceOK = "source-ok"
  public static let stagingBuild = "staging-build"
  public static let backupPlan = "backup-plan"
  public static let profileIntact = "profile-intact"
  /// Print order of the `second` preflight.
  public static let order = [
    updateLock, notRunning, notHostedInside, identityPresent, diskSpace, vendorIdle, sourceOK, stagingBuild, backupPlan, profileIntact,
  ]

  public let id: String
  public let passed: Bool
  public let detail: String

  public init(id: String, passed: Bool, detail: String) {
    self.id = id
    self.passed = passed
    self.detail = detail
  }

  public var line: String { "\(passed ? "PASS" : "FAIL") \(id) — \(detail)" }
}

/// The individual, side-effect-free checks of the `second` preflight (the staging build lives in `RebuildSecond`).
enum PreflightCheck {
  static func notRunning(_ env: RebuildEnvironment, spec: CloneSpec) async -> PreflightItem {
    let running = await env.running.isRunning(bundleId: spec.bundleId, profileDir: spec.profileDir)
    return PreflightItem(id: PreflightItem.notRunning, passed: !running,
                         detail: running ? "\(spec.displayName) (\(spec.bundleId)) is running — quit it first" : "not running")
  }

  static func notHostedInside(_ env: RebuildEnvironment, live: URL) -> PreflightItem {
    let chain = env.ancestry.ancestorExecutablePaths()
    let inside = AncestryCheck.anyInside(live, chain)
    var detail = inside ? "this session runs inside \(live.path)" : "no ancestor inside \(live.lastPathComponent)"
    if let version = env.hostAppVersion {
      detail += "; session hosted by \(AncestryCheck.hostApp(in: chain) ?? "an unknown app") "
        + "(CLAUDE_CODE_DESKTOP_APP_VERSION=\(version))"
    }
    return PreflightItem(id: PreflightItem.notHostedInside, passed: !inside, detail: detail)
  }

  static func identityPresent(_ env: RebuildEnvironment) async -> PreflightItem {
    let status = await env.identity.evaluate()
    return PreflightItem(id: PreflightItem.identityPresent, passed: status.passed, detail: status.detail)
  }

  static func diskSpace(_ env: RebuildEnvironment, source: URL) -> PreflightItem {
    let needed = BuildEnvironment.defaultMinimumFreeBytes + env.directorySize(source)
    let free = env.availableBytes(env.paths.dataDir) ?? 0
    let detail = "\(gigabytes(free)) free, \(gigabytes(needed)) needed"
    return PreflightItem(id: PreflightItem.diskSpace, passed: free >= needed, detail: detail)
  }

  /// Fails only while ShipIt installs; a downloaded update waiting for Claude to quit leaves the bundle alone.
  static func vendorIdle(_ vendor: any VendorUpdateChecking) async -> PreflightItem {
    let (passed, detail) = switch await vendor.state() {
    case .idle: (true, "ShipIt idle")
    case .waitingForQuit: (true, "update pending — ShipIt waits for Claude to quit (safe to build)")
    case .installing: (false, "Claude is being updated right now — retry in a minute")
    }
    return PreflightItem(id: PreflightItem.vendorIdle, passed: passed, detail: detail)
  }

  static func sourceOK(_ env: RebuildEnvironment, source: URL) async -> PreflightItem {
    do {
      let info = try await env.sourceProbe(source)
      return PreflightItem(id: PreflightItem.sourceOK, passed: true, detail: "\(info.version) team \(info.teamId)")
    } catch {
      return PreflightItem(id: PreflightItem.sourceOK, passed: false, detail: String(describing: error))
    }
  }

  /// The profile exists (read-only) and the staged launcher config points at exactly that directory.
  static func profileIntact(spec: CloneSpec, stagedApp: URL?) -> PreflightItem {
    let profile = spec.profileDir.path
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: profile, isDirectory: &isDir), isDir.boolValue else {
      return PreflightItem(id: PreflightItem.profileIntact, passed: false, detail: "\(profile) missing")
    }
    guard let stagedApp else {
      return PreflightItem(id: PreflightItem.profileIntact, passed: false, detail: "no staged build to compare with \(profile)")
    }
    let configURL = stagedApp.appendingPathComponent("Contents/Resources/\(LauncherConfigFile.fileName)")
    let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(LauncherConfigFile.self, from: $0) }
    guard let config, config.profileDir == profile else {
      return PreflightItem(id: PreflightItem.profileIntact, passed: false,
                           detail: "staged launcher points at \(config?.profileDir ?? "nothing"), expected \(profile)")
    }
    return PreflightItem(id: PreflightItem.profileIntact, passed: true, detail: "\(profile) (launcher config matches)")
  }

  static func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
  }
}
