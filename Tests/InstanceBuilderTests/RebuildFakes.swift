import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// An ordered record of what fakes were asked to do.
final class EventLog: Sendable {
  private let events = Mutex<[String]>([])
  func add(_ event: String) { events.withLock { $0.append(event) } }
  var all: [String] { events.withLock { $0 } }
}

/// Builds nothing: writes a staged `<name>.app` (launcher config included) into a fresh staging dir, logs
/// `build(<intent>,<identity kind>)` and returns a report.
final class FakeCloneBuilder: CloneBuilding {
  let paths: Paths
  let log: EventLog
  let verified: Bool
  let marker: String
  let launcherProfile: String?
  private let counter = Mutex(0)

  init(paths: Paths, log: EventLog, verified: Bool = true, marker: String = "new", launcherProfile: String? = nil) {
    self.paths = paths
    self.log = log
    self.verified = verified
    self.marker = marker
    self.launcherProfile = launcherProfile
  }

  func build(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent) async throws -> BuildReport {
    let n = counter.withLock { value -> Int in value += 1; return value }
    log.add("build(\(intent.rawValue),\(identity.kind),\(spec.slug.raw))")
    let dir = try StagingArea(paths: paths, timeZone: .gmt)
      .newBuildDir(slug: spec.slug, now: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)))
    let app = dir.appendingPathComponent("\(spec.displayName).app", isDirectory: true)
    try MiniBundle.write(Data("<plist>\(marker)</plist>".utf8), app.appendingPathComponent("Contents/Info.plist"))
    try MiniBundle.write(Data(marker.utf8), app.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
    let config = LauncherConfigFile(spec: launcherProfile.map { spec.with(profileDir: URL(fileURLWithPath: $0)) } ?? spec,
                                    logsDir: paths.logsDir)
    try MiniBundle.write(try config.encoded(), app.appendingPathComponent("Contents/Resources/\(LauncherConfigFile.fileName)"))
    let report = BuildReport(
      slug: spec.slug.raw, bundleId: spec.bundleId, displayName: spec.displayName, badge: spec.badge,
      intent: intent, sourcePath: source.path,
      sourceVersion: AppVersion.read(source) ?? "2.0.0",
      stagedPath: app.path, identityKind: identity.kind, steps: [], verification: [],
      smoke: [SmokeCheck(name: "info-id", passed: true, detail: spec.bundleId)],
      designatedRequirement: "identifier \"\(spec.bundleId)\" and certificate leaf = H\"ABC\"", requirementFile: nil,
      failure: verified ? nil : BuildFailure(step: "verify", message: "boom"), verified: verified,
      startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1))
    try JSONCoding.encoder.encode(report).write(to: dir.appendingPathComponent("build-report.json"))
    return report
  }
}

/// Not running for the first `runningFromCall - 1` queries, running from then on (a clone launched mid-apply).
final class FlipRunningCheck: RunningChecking {
  let runningFromCall: Int
  private let calls = Mutex(0)

  init(runningFromCall: Int) {
    self.runningFromCall = runningFromCall
  }

  func isRunning(bundleId: String, profileDir: URL?) async -> Bool {
    calls.withLock { value -> Bool in value += 1; return value >= runningFromCall }
  }
}

/// Running state per bundle id that a test can change between passes.
final class MutableRunningSet: RunningChecking {
  private let running: Mutex<Set<String>>

  init(_ running: Set<String>) {
    self.running = Mutex(running)
  }

  func set(_ value: Set<String>) { running.withLock { $0 = value } }
  func isRunning(bundleId: String, profileDir: URL?) async -> Bool { running.withLock { $0.contains(bundleId) } }
}

/// Logs `register(<app>,<marker>)` and `unregister(<parent>/<app>)`; `unregister` throws (after logging) when
/// `unregisterFails`.
struct FakeRegistrar: AppRegistering {
  let log: EventLog
  var unregisterFails = false

  func register(_ app: URL) async throws {
    let marker = (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Claude"))).map { String(decoding: $0, as: UTF8.self) }
    log.add("register(\(app.lastPathComponent),\(marker ?? "?"))")
  }

  func unregister(_ app: URL) async throws {
    log.add("unregister(\(app.deletingLastPathComponent().lastPathComponent)/\(app.lastPathComponent))")
    if unregisterFails { throw BuilderError.commandFailed(tool: "lsregister", exitCode: 1, stderr: "unregister failed") }
  }
}

/// `security find-certificate` output listing `sha1`, everything else succeeds silently.
func securityRunner(listing sha1: String?) -> ScriptedRunner {
  ScriptedRunner { request in
    guard request.executable.lastPathComponent == "security" else { return .ok() }
    guard let sha1 else { return .fail(44, stderr: "The specified item could not be found in the keychain.") }
    return .ok(stdout: "keychain: \"/Users/u/Library/Keychains/login.keychain-db\"\nSHA-1 hash: \(sha1)\nSHA-256 hash: 00\n")
  }
}

let testSHA1 = String(repeating: "AB", count: 20)

/// Writes `builder.signingIdentitySHA1` and `signing/identity.json` like `scripts/signing-setup.sh`.
func installIdentity(_ paths: Paths, sha1: String = testSHA1) throws {
  try FileManager.default.createDirectory(at: paths.signingDir, withIntermediateDirectories: true)
  try Data("{\"builder\":{\"signingIdentitySHA1\":\"\(sha1)\"}}".utf8).write(to: paths.settingsFile)
  try Data("{\"sha1\":\"\(sha1)\"}".utf8).write(to: paths.identityFile)
}
