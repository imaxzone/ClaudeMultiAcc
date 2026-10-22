import Foundation

enum LauncherConfigError: Error, Equatable {
  case missing
  case invalid(String)
}

/// `Contents/Resources/ClaudeMultiAcc-launcher.json`, written by InstanceBuilder's `LauncherInstaller`.
struct LauncherConfig: Codable, Equatable {
  static let resourceName = "ClaudeMultiAcc-launcher"
  let schemaVersion: Int
  let slug: String
  let bundleId: String
  let profileDir: String
  let realExecutable: String
  let logFile: String

  static func decode(_ data: Data) throws -> LauncherConfig {
    let config: LauncherConfig
    do {
      config = try JSONDecoder().decode(LauncherConfig.self, from: data)
    } catch {
      throw LauncherConfigError.invalid("undecodable: \(error)")
    }
    guard config.schemaVersion == 1 else { throw LauncherConfigError.invalid("schemaVersion \(config.schemaVersion)") }
    guard !config.realExecutable.isEmpty, !config.realExecutable.contains("/"), config.realExecutable != ".."
    else { throw LauncherConfigError.invalid("realExecutable") }
    guard config.profileDir.hasPrefix("/"), config.logFile.hasPrefix("/") else {
      throw LauncherConfigError.invalid("paths must be absolute")
    }
    return config
  }

  static func load(from bundle: Bundle) throws -> LauncherConfig {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
          let data = try? Data(contentsOf: url)
    else { throw LauncherConfigError.missing }
    return try decode(data)
  }
}
