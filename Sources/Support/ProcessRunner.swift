import Foundation

/// A subprocess invocation. Arguments are always an array; there is no shell (G9).
public struct ProcessRequest: Sendable {
  public var executable: URL
  public var arguments: [String]
  /// `nil` inherits the parent environment; `[:]` runs with an empty environment.
  public var environment: [String: String]?
  public var currentDirectory: URL?
  public var timeout: Duration
  /// `nil` connects stdin to `/dev/null`.
  public var stdin: Data?

  public init(
    executable: URL, arguments: [String] = [], environment: [String: String]? = nil,
    currentDirectory: URL? = nil, timeout: Duration, stdin: Data? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.currentDirectory = currentDirectory
    self.timeout = timeout
    self.stdin = stdin
  }
}

public struct ProcessResult: Sendable, Equatable {
  public let exitCode: Int32
  public let stdout: Data
  public let stderr: Data
  public let timedOut: Bool
  /// The stream was longer than the runner's capture limit; only its first bytes are kept.
  public let stdoutTruncated: Bool
  public let stderrTruncated: Bool

  public init(
    exitCode: Int32, stdout: Data, stderr: Data, timedOut: Bool, stdoutTruncated: Bool = false,
    stderrTruncated: Bool = false
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

  public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
  public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Equatable {
  case launchFailed(executable: String, reason: String)
}

public protocol ProcessRunning: Sendable {
  func run(_ request: ProcessRequest) async throws -> ProcessResult
}
