import Foundation
import Synchronization
import Testing
import Support
@testable import UI

func makeTempDir(_ name: String = #function) throws -> URL {
  let safe = name.filter { $0.isLetter || $0.isNumber }
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("cmacc-ui-tests-\(safe)-\(UUID().uuidString)", isDirectory: true)
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

func fixtureText(_ name: String, root: URL) throws -> String {
  let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  return try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    .replacingOccurrences(of: "{{ROOT}}", with: root.path)
}

func slug(_ raw: String) -> Slug {
  do { return try Slug(raw) } catch { fatalError("bad test slug \(raw)") }
}
