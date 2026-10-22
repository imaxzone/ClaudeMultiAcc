import Foundation

/// Every on-disk location the tool uses (G1). Injected everywhere so tests stay hermetic (G6).
public struct Paths: Sendable, Equatable {
  public let home: URL
  public let dataDir: URL
  public let logsDir: URL

  public init(home: URL, dataDir: URL? = nil, logsDir: URL? = nil) {
    self.home = home
    self.dataDir = dataDir ?? home.appendingPathComponent("Library/Application Support/ClaudeMultiAcc", isDirectory: true)
    self.logsDir = logsDir ?? home.appendingPathComponent("Library/Logs/ClaudeMultiAcc", isDirectory: true)
  }

  /// Real locations, honouring `CMACC_HOME`, `CMACC_DATA_DIR` and `CMACC_LOGS_DIR`.
  public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
    func dir(_ key: String) -> URL? {
      guard let value = environment[key], !value.isEmpty else { return nil }
      return URL(fileURLWithPath: value, isDirectory: true)
    }
    return Paths(
      home: dir("CMACC_HOME") ?? FileManager.default.homeDirectoryForCurrentUser,
      dataDir: dir("CMACC_DATA_DIR"),
      logsDir: dir("CMACC_LOGS_DIR")
    )
  }

  public var instancesFile: URL { dataDir.appendingPathComponent("instances.json") }
  public var settingsFile: URL { dataDir.appendingPathComponent("settings.json") }

  public var stagingDir: URL { dataDir.appendingPathComponent("staging", isDirectory: true) }
  public var backupDir: URL { dataDir.appendingPathComponent("backup", isDirectory: true) }
  public var signingDir: URL { dataDir.appendingPathComponent("signing", isDirectory: true) }
  public var requirementFile: URL { signingDir.appendingPathComponent("requirement.txt") }
  public var identityFile: URL { signingDir.appendingPathComponent("identity.json") }

  public var cliAccountsRoot: URL { home.appendingPathComponent(".claude-accounts", isDirectory: true) }

  /// Creates the data and log directories; private ones are forced to 0700 even if they already exist.
  public func ensureDataDirs() throws {
    let privateDirs = [dataDir, signingDir, logsDir]
    for dir in [dataDir, stagingDir, backupDir, signingDir, logsDir] {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    for dir in privateDirs {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
  }
}
