import Foundation
import Synchronization
import Support
import Testing
@testable import LinkRouter

func makeTempDir(_ name: String = #function) throws -> URL {
  let safe = name.filter { $0.isLetter || $0.isNumber }
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("cmacc-router-tests-\(safe)-\(UUID().uuidString)", isDirectory: true)
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

func fixtureURL(_ name: String) throws -> URL {
  let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  return dir.appendingPathComponent(name)
}

func fixtureText(_ name: String, root: URL) throws -> String {
  try String(contentsOf: fixtureURL(name), encoding: .utf8).replacingOccurrences(of: "{{ROOT}}", with: root.path)
}

/// The four-instance registry (official `main`, clones `second` and `work`, CLI-only `alt`) rooted at `root`.
func fourInstances(root: URL) throws -> [Instance] {
  struct File: Decodable { let instances: [Instance] }
  return try JSONDecoder().decode(File.self, from: Data(try fixtureText("instances-four.json", root: root).utf8)).instances
}

func slug(_ raw: String) -> Slug {
  do { return try Slug(raw) } catch { fatalError("bad test slug \(raw)") }
}

func url(_ string: String) -> URL {
  guard let url = URL(string: string) else { fatalError("bad test url \(string)") }
  return url
}

let testNow = Date(timeIntervalSince1970: 1_790_210_000)

final class MutableClock: Clock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ now: Date = testNow) { value = now }
  var now: Date {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A clone candidate with made-up paths.
func candidate(_ raw: String) -> SignInCandidate {
  SignInCandidate(
    slug: raw, bundleId: "com.example.claude.\(raw)", appPath: URL(fileURLWithPath: "/Applications/Claude \(raw).app"),
    profileDir: URL(fileURLWithPath: "/tmp/profiles/\(raw)", isDirectory: true))
}

/// Profiles whose path is in `signedIn` are signed in; all others are not.
struct FakeProfiles: SignInStateReading {
  var signedIn: Set<String> = []
  func isSignedIn(profileDir: URL) -> Bool { signedIn.contains(profileDir.lastPathComponent) }
}

/// Writes `<profile>/config.json`, creating the profile directory.
func writeConfig(_ json: String, profile: URL) throws {
  try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
  try Data(json.utf8).write(to: profile.appendingPathComponent("config.json"))
}

func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

let magicLink = url("claude://claude.ai/magic-link#0123456789abcdef0123456789abcdef:\(base64("nobody@example.com"))")
let googleLink = url("claude://login/google-auth?code=abc&hop_nonce=x")
let newChatLink = url("claude://claude.ai/new?q=ping")
