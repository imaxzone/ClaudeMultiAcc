import Foundation
import Support

/// Where `rebuild --apply` would move the live app: `<data>/backup/[legacy-]<name>.app.<yyyyMMdd-HHmmss>`. The
/// rename only works on the volume of `/Applications`, and an existing target is never overwritten.
public struct BackupPlan: Sendable, Equatable {
  /// Prefix of the backup of a clone built by the legacy script; such backups are never pruned.
  public static let legacyPrefix = "legacy-"

  public let target: URL

  public init(backupDir: URL, appName: String, now: Date, timeZone: TimeZone = .current, prefix: String = "") {
    target = backupDir.appendingPathComponent("\(prefix)\(appName).\(Timestamp.stamp(now, timeZone: timeZone))")
  }

  public func evaluate(applicationsDir: URL, volume: @Sendable (URL) -> String?) -> PreflightItem {
    let backupVolume = volume(target.deletingLastPathComponent())
    let appsVolume = volume(applicationsDir)
    guard let backupVolume, backupVolume == appsVolume else {
      return PreflightItem(id: PreflightItem.backupPlan, passed: false,
                           detail: "\(target.deletingLastPathComponent().path) is not on the volume of \(applicationsDir.path)")
    }
    guard !FileManager.default.fileExists(atPath: target.path) else {
      return PreflightItem(id: PreflightItem.backupPlan, passed: false, detail: "\(target.path) already exists")
    }
    return PreflightItem(id: PreflightItem.backupPlan, passed: true, detail: target.path)
  }
}
