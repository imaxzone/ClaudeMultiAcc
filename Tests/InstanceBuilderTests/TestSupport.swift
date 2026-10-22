import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// Creates a unique temporary directory for a single test.
func makeTempDir(_ name: String = #function) throws -> URL {
  let safe = name.filter { $0.isLetter || $0.isNumber }
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("cmacc-ib-\(safe)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return TempDirs.register(url)
}

/// Every directory made by `makeTempDir` in this test process; all are removed by one `atexit` handler (S12).
enum TempDirs {
  private static let dirs = Mutex<[URL]>([])
  private static let cleanupInstalled: Void = { atexit { TempDirs.removeAll() } }()

  static func register(_ url: URL) -> URL {
    _ = cleanupInstalled
    dirs.withLock { $0.append(url) }
    return url
  }

  static func removeAll() {
    for url in dirs.withLock({ $0 }) {
      chmod(url.path, 0o700)
      try? FileManager.default.removeItem(at: url)
    }
  }
}

/// The repository checkout this test file belongs to (for `scripts/`).
enum Repo {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
}

func fixtureURL(_ name: String) throws -> URL {
  let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  return dir.appendingPathComponent(name)
}

func fixtureData(_ name: String) throws -> Data {
  try Data(contentsOf: fixtureURL(name))
}

func plistDict(_ data: Data) throws -> [String: Any] {
  let object = try PropertyListSerialization.propertyList(from: data, format: nil)
  return try #require(object as? [String: Any])
}

func testSlug(_ raw: String) -> Slug {
  // swiftlint:disable:next force_try
  try! Slug(raw)
}

/// A fake `ProcessRunning` that records every request and answers from a handler.
final class ScriptedRunner: ProcessRunning {
  typealias Handler = @Sendable (ProcessRequest) throws -> ProcessResult
  private let requests = Mutex<[ProcessRequest]>([])
  private let handler: Handler

  init(handler: @escaping Handler = { _ in .ok() }) {
    self.handler = handler
  }

  var recorded: [ProcessRequest] { requests.withLock { $0 } }
  var responder: Handler { handler }
  var commandLines: [[String]] { recorded.map { [$0.executable.lastPathComponent] + $0.arguments } }

  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    requests.withLock { $0.append(request) }
    return try handler(request)
  }
}

extension ProcessResult {
  static func ok(stdout: String = "", stderr: String = "") -> ProcessResult {
    ProcessResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), timedOut: false)
  }

  static func fail(_ code: Int32 = 1, stderr: String = "failed") -> ProcessResult {
    ProcessResult(exitCode: code, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
  }
}
