import Foundation
import Support

/// Absolute paths of the system tools the builder runs, always with argument arrays (G9).
enum BuilderTool {
  static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
  static let cp = URL(fileURLWithPath: "/bin/cp")
  static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
  static let xattr = URL(fileURLWithPath: "/usr/bin/xattr")
  static let lsappinfo = URL(fileURLWithPath: "/usr/bin/lsappinfo")
  static let launchctl = URL(fileURLWithPath: "/bin/launchctl")
  static let security = URL(fileURLWithPath: "/usr/bin/security")
  static let lsregister = URL(fileURLWithPath:
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")

  static let shortTimeout: Duration = .seconds(30)
  static let signTimeout: Duration = .seconds(300)
  static let copyTimeout: Duration = .seconds(900)
}

extension ProcessRunning {
  /// Runs `tool`; throws `.commandTimedOut` on timeout, returns the result whatever the exit code.
  func runTool(_ tool: URL, _ arguments: [String], timeout: Duration) async throws -> ProcessResult {
    let result = try await run(ProcessRequest(executable: tool, arguments: arguments, timeout: timeout))
    if result.timedOut { throw BuilderError.commandTimedOut(tool.lastPathComponent) }
    return result
  }

  /// Like `runTool`, but a non-zero exit throws `.commandFailed` with the trimmed stderr.
  @discardableResult
  func runChecked(_ tool: URL, _ arguments: [String], timeout: Duration) async throws -> ProcessResult {
    let result = try await runTool(tool, arguments, timeout: timeout)
    guard result.exitCode == 0 else {
      throw BuilderError.commandFailed(
        tool: tool.lastPathComponent, exitCode: result.exitCode,
        stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result
  }
}
