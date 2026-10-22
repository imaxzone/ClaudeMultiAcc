import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// The live build environment's ShipIt gate: the official app's ShipIt can replace only the official app, never a
/// Claude ClaudeMultiAcc downloaded itself.
@Suite struct BuildEnvironmentTests {
  /// ShipIt's launchd job reports `state = running`; nothing else runs.
  static let shipItRunning = ScriptedRunner { request in
    request.executable.lastPathComponent == "launchctl" ? .ok(stdout: "\tstate = running\n") : .ok()
  }

  @Test func shipItNeverBlocksADownloadedSource() async throws {
    let root = try makeTempDir()
    let downloads = root.appendingPathComponent("data/source", isDirectory: true)
    let environment = BuildEnvironment.live(runner: Self.shipItRunning, downloads: downloads)
    let downloaded = downloads.appendingPathComponent("3.1623.3.noindex/Claude.app", isDirectory: true)
    #expect(await environment.vendorUpdate(downloaded).state() == .idle)
    let official = root.appendingPathComponent("Applications/Claude.app", isDirectory: true)
    #expect(await environment.vendorUpdate(official).state() == .installing)
  }

  @Test func withoutADownloadsFolderEverySourceIsChecked() async throws {
    let root = try makeTempDir()
    let environment = BuildEnvironment.live(runner: Self.shipItRunning)
    let downloaded = root.appendingPathComponent("data/source/3.1623.3.noindex/Claude.app", isDirectory: true)
    #expect(await environment.vendorUpdate(downloaded).state() == .installing)
  }
}
