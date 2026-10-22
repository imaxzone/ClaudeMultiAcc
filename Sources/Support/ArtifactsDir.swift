import Foundation

/// Where tests and diagnostics write images and other artifacts (G6).
public enum ArtifactsDir {
  public static let environmentKey = "CMACC_ARTIFACTS_DIR"

  public static var url: URL { url(environment: ProcessInfo.processInfo.environment) }

  public static func url(environment: [String: String]) -> URL {
    if let override = environment[environmentKey], !override.isEmpty {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("ClaudeMultiAcc-artifacts", isDirectory: true)
  }
}
