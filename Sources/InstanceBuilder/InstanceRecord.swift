import Foundation
import Support

extension Instance {
  /// A copy with new build bookkeeping (everything else unchanged).
  func withBuild(builtBy: String?, pendingBuild: String?) -> Instance {
    Instance(
      slug: slug, name: name, kind: kind, bundleId: bundleId, appPath: appPath, profileDir: profileDir,
      accountUuid: accountUuid, orgUuid: orgUuid, emails: emails, cliConfigDir: cliConfigDir, badge: badge,
      builtBy: builtBy, pendingBuild: pendingBuild)
  }

  /// The `CFBundleShortVersionString` of the installed app (read-only), if any.
  var installedVersion: String? {
    appPath.flatMap { AppVersion.read(URL(fileURLWithPath: $0, isDirectory: true)) }
  }
}

/// Reads `CFBundleShortVersionString` from `<app>/Contents/Info.plist` (read-only).
public enum AppVersion {
  public static func read(_ app: URL) -> String? {
    let url = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: url), let info = try? PlistPatcher.decode(data) else { return nil }
    return info["CFBundleShortVersionString"] as? String
  }
}
