import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct PreflightTests {
  @Test func lsappinfoOutputMeansRunning() async {
    let runner = ScriptedRunner { _ in .ok(stdout: "ASN:0x0-0x1d01d:\n") }
    #expect(await RunningCheck(runner: runner).isRunning(bundleId: "com.imaxzone.claude.none-such-app"))
    #expect(runner.commandLines == [["lsappinfo", "find", "bundleid=com.imaxzone.claude.none-such-app"]])
  }

  @Test func emptyLsappinfoMeansNotRunning() async {
    let runner = ScriptedRunner { _ in .ok(stdout: "\n") }
    #expect(await RunningCheck(runner: runner).isRunning(bundleId: "com.imaxzone.claude.none-such-app") == false)
  }

  @Test func heldCloneLockMeansRunning() async throws {
    let profile = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: profile) }
    let runner = ScriptedRunner { _ in .ok() }
    let check = RunningCheck(runner: runner)
    #expect(await check.isRunning(bundleId: "com.imaxzone.claude.none-such-app", profileDir: profile) == false)
    // O_CLOEXEC: a tool spawned by a concurrent test must not inherit (and keep holding) the lock.
    let fd = open(profile.appendingPathComponent(".clone.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
    // flock locks are per open file description, so a second open() in this process conflicts.
    #expect(await check.isRunning(bundleId: "com.imaxzone.claude.none-such-app", profileDir: profile))
    close(fd)
    #expect(await check.isRunning(bundleId: "com.imaxzone.claude.none-such-app", profileDir: profile) == false)
  }

  static let claude = URL(fileURLWithPath: "/Applications/Claude.app")
  static let shipItPath = "/Applications/Claude.app/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt"
  static let launchctlRunning = "com.anthropic.claudefordesktop.ShipIt = {\n\tstate = running\n}\n"

  private func vendorCheck(
    launchctl: ScriptedRunner, processes: [String], sourceRunning: Bool
  ) -> VendorUpdateCheck {
    VendorUpdateCheck(runner: launchctl, sourceApp: Self.claude, uid: 501, processPaths: { processes },
                      isSourceRunning: { sourceRunning })
  }

  /// ShipIt only replaces the bundle after the official app quit: running app → waiting, no app → installing.
  @Test(arguments: [
    ("absent", false, VendorUpdateState.idle), ("absent", true, .idle),
    ("process", true, .waitingForQuit), ("process", false, .installing),
    ("launchctl", true, .waitingForQuit), ("launchctl", false, .installing),
    ("not-running", false, .idle), ("exit-113", false, .idle),
  ])
  func vendorUpdateStateTable(shipIt: String, sourceRunning: Bool, expected: VendorUpdateState) async {
    let runner = ScriptedRunner { _ in
      switch shipIt {
      case "launchctl": .ok(stdout: Self.launchctlRunning)
      case "not-running": .ok(stdout: "state = not running\n")
      default: .fail(113, stderr: "Could not find service")
      }
    }
    let processes = shipIt == "process" ? [Self.shipItPath] : ["/usr/bin/true", "/Applications/Claude.app/Contents/MacOS/Claude"]
    let check = vendorCheck(launchctl: runner, processes: processes, sourceRunning: sourceRunning)
    #expect(await check.state() == expected, "\(shipIt) sourceRunning=\(sourceRunning)")
  }

  @Test func launchctlQueriesTheShipItService() async {
    let runner = ScriptedRunner { _ in .ok(stdout: Self.launchctlRunning) }
    _ = await vendorCheck(launchctl: runner, processes: [], sourceRunning: false).state()
    #expect(runner.commandLines == [["launchctl", "print", "gui/501/com.anthropic.claudefordesktop.ShipIt"]])
  }

  @Test func sourceBundleIdComesFromInfoPlistWithVendorFallback() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Claude.app")
    #expect(VendorUpdateCheck.bundleId(of: app) == "com.anthropic.claudefordesktop")
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.custom"], format: .xml, options: 0)
    try MiniBundle.write(info, app.appendingPathComponent("Contents/Info.plist"))
    #expect(VendorUpdateCheck.bundleId(of: app) == "com.example.custom")
  }

  static let stray = URL(fileURLWithPath: "/Users/x/Downloads/Claude.app")
  static let vendorId = "com.anthropic.claudefordesktop"

  /// `lsappinfo find` answers `find`; `info` reports `infoPath` (nil → the call fails).
  private func lsappinfo(find: ProcessResult, infoPath: String?, launchctl: String = "") -> ScriptedRunner {
    ScriptedRunner { request in
      switch (request.executable.lastPathComponent, request.arguments.first) {
      case ("launchctl", _): launchctl.isEmpty ? .fail(113) : .ok(stdout: launchctl)
      case ("lsappinfo", "find"): find
      case ("lsappinfo", "info"):
        infoPath.map { .ok(stdout: "[ NULL ]  ASN:0x0-0x8b08b: (in front) \n    bundle path=\"\($0)\"\n") } ?? .fail(1)
      default: .fail(127)
      }
    }
  }

  private static let found = ProcessResult.ok(stdout: "ASN:0x0-0x8b08b-\"Claude\":\n")

  @Test func runningAtPathUsesTheWorkspaceBundleURL() async {
    let runner = lsappinfo(find: .fail(1), infoPath: nil)
    let at = RunningCheck(runner: runner, runningAppURLs: { _ in [Self.stray, Self.claude] })
    #expect(await at.isRunning(bundleId: Self.vendorId, at: Self.claude))
    #expect(runner.recorded.isEmpty)
  }

  @Test func aStrayCopyWithTheSameBundleIdIsNotTheSource() async {
    let runner = lsappinfo(find: Self.found, infoPath: Self.stray.path)
    let check = RunningCheck(runner: runner, runningAppURLs: { _ in [Self.stray] })
    #expect(await check.isRunning(bundleId: Self.vendorId, at: Self.claude) == false)
    #expect(runner.commandLines.last == ["lsappinfo", "info", "-only", "bundlepath", "ASN:0x0-0x8b08b:"])
  }

  @Test func lsappinfoCountsOnlyWhenItsBundlePathIsTheSource() async {
    let match = RunningCheck(runner: lsappinfo(find: Self.found, infoPath: Self.claude.path), runningAppURLs: { _ in [] })
    #expect(await match.isRunning(bundleId: Self.vendorId, at: Self.claude))
    for runner in [lsappinfo(find: Self.found, infoPath: nil), lsappinfo(find: .ok(stdout: "\n"), infoPath: Self.claude.path),
                   lsappinfo(find: .fail(1), infoPath: Self.claude.path)] {
      let check = RunningCheck(runner: runner, runningAppURLs: { _ in [] })
      #expect(await check.isRunning(bundleId: Self.vendorId, at: Self.claude) == false)
    }
  }

  @Test func runningAtPathResolvesSymlinks() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("Real/Claude.app")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("Link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
    let check = RunningCheck(runner: lsappinfo(find: .fail(1), infoPath: nil),
                             runningAppURLs: { _ in [link.appendingPathComponent("Claude.app")] })
    #expect(await check.isRunning(bundleId: Self.vendorId, at: real))
  }

  /// ShipIt active, lsappinfo failing or empty, only a stray copy running → treated as installing (fail safe).
  @Test func shipItWithoutTheSourceRunningFailsSafeToInstalling() async {
    for find in [ProcessResult.fail(1), .ok(stdout: "")] {
      let runner = lsappinfo(find: find, infoPath: nil, launchctl: Self.launchctlRunning)
      let running = RunningCheck(runner: runner, runningAppURLs: { _ in [Self.stray] })
      let check = VendorUpdateCheck(runner: runner, sourceApp: Self.claude, uid: 501, processPaths: { [] },
                                    isSourceRunning: { await VendorUpdateCheck.isRunning(Self.claude, check: running) })
      #expect(await check.state() == .installing)
    }
  }

  @Test func liveProcessPathsIncludeThisProcess() {
    let paths = VendorUpdateCheck.allProcessPaths()
    #expect(!paths.isEmpty)
  }
}
