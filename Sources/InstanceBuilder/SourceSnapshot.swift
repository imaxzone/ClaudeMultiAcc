import Foundation
import Support

/// Everything the steps after `recheck-source` take from the source (entitlements, smoke reference). Captured before that guard, so a vendor update replacing the source afterwards cannot mix
/// version N+1 parts into a copy of version N.
struct SourceSnapshot {
  let facts: SourceFacts
  let entitlements: (url: URL, data: Data)
  let entitlementsDetail: String

  var detail: String {
    "\(entitlementsDetail) entitlements, \(facts.helperIds.count) helpers"
  }
}

/// `preflight`'s smoke checks: `target-running`, plus `vendor-update-pending` while ShipIt waits for Claude to quit.
struct PreflightResult {
  let target: SmokeCheck
  let vendorPending: SmokeCheck?

  var checks: [SmokeCheck] { [target] + (vendorPending.map { [$0] } ?? []) }
}

extension InstanceBuildPipeline {
  /// Refuses while the vendor updater installs (Claude quit mid-build); a pending update is fine.
  func requireVendorNotInstalling(_ source: URL) async throws {
    if await environment.vendorUpdate(source).state() == .installing { throw BuilderError.vendorUpdateActive }
  }

  /// `teamId` comes from `probe`; `recheck-source` later proves the source (version, main executable) unchanged.
  func captureSource(_ source: URL, buildDir: URL, teamId: String) async throws -> (SourceSnapshot, String) {
    let (entitlements, entitlementsDetail) = try await filteredEntitlements(source: source, buildDir: buildDir)
    let snapshot = SourceSnapshot(facts: SourceFacts.read(from: source, teamId: teamId), entitlements: entitlements,
                                  entitlementsDetail: entitlementsDetail)
    return (snapshot, snapshot.detail)
  }

  /// After the copy and the snapshot: ShipIt is not installing, and the source still has the probed version and
  /// main executable. Otherwise the copy (and the snapshot) may mix two vendor versions.
  func recheckSource(_ source: URL, against info: SourceInfo) async throws -> String {
    try await requireVendorNotInstalling(source)
    let plist = try? PlistPatcher.decode(Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")))
    let version = plist?["CFBundleShortVersionString"] as? String ?? "unknown"
    guard version == info.version, SourceProbe.mainExecutableHash(source) == info.mainExecutableSHA256 else {
      throw BuilderError.sourceChangedDuringCopy
    }
    return "version \(info.version) and main executable unchanged"
  }
}
