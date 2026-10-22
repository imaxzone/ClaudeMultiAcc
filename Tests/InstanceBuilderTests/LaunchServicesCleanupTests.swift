import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// The start-up sweep and `Registrar.unregister`: LaunchServices forgets backups, staged builds, downloaded Claude
/// sources and stale records under the data folder. No real `lsregister` runs: a scripted runner answers the dump and
/// records every `-u`.
@Suite struct LaunchServicesCleanupTests {
  struct Fixture {
    let root: URL
    let paths: Paths
    var data: URL { paths.dataDir }
    var updatesLog: String {
      (try? String(contentsOf: paths.logsDir.appendingPathComponent("updates.log"), encoding: .utf8)) ?? ""
    }
  }

  func fixture(_ name: String = #function) throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    try paths.ensureDataDirs()
    return Fixture(root: root, paths: paths)
  }

  /// Answers `lsregister -dump Bundle` with `dump` (or exits `dumpExit`) and `lsregister -u` with `unregisterExit`.
  func lsregister(dump: String = "", dumpExit: Int32 = 0, unregisterExit: Int32 = 0) -> ScriptedRunner {
    ScriptedRunner { request in
      guard request.executable == BuilderTool.lsregister else { return .fail(99, stderr: "unexpected tool") }
      if request.arguments.first == "-dump" { return dumpExit == 0 ? .ok(stdout: dump) : .fail(dumpExit) }
      return unregisterExit == 0 ? .ok() : .fail(unregisterExit, stderr: "no such bundle")
    }
  }

  /// The paths given to `lsregister -u`, relative to the data folder.
  func unregistered(_ runner: ScriptedRunner, _ f: Fixture) -> [String] {
    let base = f.data.path + "/"
    return runner.recorded.filter { $0.arguments.first == "-u" }.compactMap(\.arguments.last)
      .map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : $0 }
  }

  func makeBundle(_ url: URL) throws {
    try MiniBundle.write(Data("x".utf8), url.appendingPathComponent("Contents/Info.plist.disabled"))
  }

  /// One bundle record as `lsregister -dump` prints it.
  func record(_ path: String, _ id: Int) -> String {
    """
    --------------------------------------------------------------------------------
    bundle id:                  X (0x\(String(id, radix: 16)))
    path:                       \(path) (0x\(String(id + 1, radix: 16)))
    directory:                  ~/Library
    """
  }

  // MARK: Registrar

  @Test func registrarUnregistersStagedAndBackupBundlesButStillRefusesToRegisterStagedOnes() async throws {
    let f = try fixture()
    let runner = lsregister()
    let registrar = Registrar(runner: runner, staging: StagingArea(paths: f.paths))
    let staged = f.paths.stagingDir.appendingPathComponent("home-20260921-141320.noindex/Claude Home.app")
    let backup = f.paths.backupDir.appendingPathComponent("Claude Home.app.20260101-000000")
    try await registrar.unregister(staged)
    try await registrar.unregister(backup)
    #expect(runner.commandLines == [["lsregister", "-u", staged.path], ["lsregister", "-u", backup.path]])
    await #expect(throws: BuilderError.stagingPathRefused(staged.path)) { try await registrar.register(staged) }
    #expect(runner.recorded.count == 2)
  }

  @Test func registrarUnregisterThrowsWhenLsregisterFails() async throws {
    let registrar = Registrar(runner: lsregister(unregisterExit: 1), staging: nil)
    await #expect(throws: BuilderError.commandFailed(tool: "lsregister", exitCode: 1, stderr: "no such bundle")) {
      try await registrar.unregister(URL(fileURLWithPath: "/x/Y.app"))
    }
  }

  // MARK: Sweep

  @Test func sweepForgetsEveryBackupAndStagedBundleButNoSymlinkOrFile() async throws {
    let f = try fixture()
    let backup = f.paths.backupDir
    try makeBundle(backup.appendingPathComponent("Claude Home.app.20260101-000000"))
    try makeBundle(backup.appendingPathComponent("legacy-Claude 2nd.app.20250101-000000"))
    try makeBundle(backup.appendingPathComponent("failed-20260301-000000/Claude 2nd.app"))
    try Data("note".utf8).write(to: backup.appendingPathComponent("notes.txt"))
    let outside = f.root.appendingPathComponent("Applications/Claude.app")
    try makeBundle(outside)
    try FileManager.default.createSymbolicLink(
      at: backup.appendingPathComponent("Claude Evil.app.20260101-000000"), withDestinationURL: outside)
    let build = f.paths.stagingDir.appendingPathComponent("home-20260921-141320.noindex")
    try makeBundle(build.appendingPathComponent("Claude Home.app/Contents/Frameworks/Claude Helper.app"))
    try Data("{}".utf8).write(to: build.appendingPathComponent("build-report.json"))
    try FileManager.default.createSymbolicLink(at: f.paths.stagingDir.appendingPathComponent("linked.app"), withDestinationURL: outside)
    let runner = lsregister()
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: runner)
    #expect(runner.commandLines.first == ["lsregister", "-dump", "Bundle"])
    #expect(unregistered(runner, f) == [
      "backup/Claude Home.app.20260101-000000", "backup/failed-20260301-000000/Claude 2nd.app",
      "backup/legacy-Claude 2nd.app.20250101-000000", "staging/home-20260921-141320.noindex/Claude Home.app",
    ])
    #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Claude Home.app.20260101-000000").path))
  }

  /// Database records: anything under backup or staging (nested helpers and deleted backups too), anything else under
  /// the data folder only when gone from disk, never anything outside it; on-disk bundles are not asked twice.
  @Test func sweepForgetsDatabaseRecordsUnderBackupOrStagingAndGoneOnes() async throws {
    let f = try fixture()
    let data = f.data.path
    try makeBundle(f.paths.backupDir.appendingPathComponent("Claude Home.app.20260101-000000"))
    try makeBundle(f.data.appendingPathComponent("tools/Kept.app"))
    let dump = [
      "Checking data integrity...",
      record("/Applications/Claude.app", 0x10),
      record("\(data)/backup/Claude Home.app.20260101-000000", 0x20),
      record("\(data)/backup/Claude Home.app.20260101-000000/Contents/Frameworks/Claude Helper (GPU).app", 0x30),
      record("\(data)/backup/Claude 5x акк.app.20261019-185659", 0x40),
      record("\(data)/staging/home-20260921-141320.noindex/Claude Home.app", 0x50),
      record("\(data)/tools/Kept.app", 0x60),
      record("\(data)/old/Gone.app", 0x70),
      "path:                       \(data)/backup/NoRecordId.app",
      record("\(f.root.path)/elsewhere/Gone.app", 0x80),
    ].joined(separator: "\n")
    let runner = lsregister(dump: dump)
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: runner)
    #expect(unregistered(runner, f) == [
      "backup/Claude Home.app.20260101-000000",
      "backup/Claude 5x акк.app.20261019-185659",
      "backup/Claude Home.app.20260101-000000/Contents/Frameworks/Claude Helper (GPU).app",
      "old/Gone.app",
      "staging/home-20260921-141320.noindex/Claude Home.app",
    ])
    #expect(f.updatesLog.contains("launchservices sweep: unregistered 5 of 5 (backups 1, staged 0, sources 0, database 4)"))
  }

  /// Downloaded Claude versions stay out of LaunchServices like backups and staging: every `<version>.noindex/Claude.app`
  /// on disk (no descent into the bundle, no symlink) and every database record under `<data>/source`.
  @Test func sweepForgetsDownloadedSources() async throws {
    let f = try fixture()
    let sources = f.paths.claudeSourcesDir
    let data = f.data.path
    try makeBundle(sources.appendingPathComponent("3.1623.3.noindex/Claude.app/Contents/Frameworks/Claude Helper.app"))
    try makeBundle(sources.appendingPathComponent("incoming.noindex/unpacked/Claude.app"))
    let outside = f.root.appendingPathComponent("Applications/Claude.app")
    try makeBundle(outside)
    try FileManager.default.createSymbolicLink(at: sources.appendingPathComponent("3.1623.4.noindex"), withDestinationURL: outside)
    let dump = [
      record("\(data)/source/3.1623.3.noindex/Claude.app", 0x10),
      record("\(data)/source/3.1623.3.noindex/Claude.app/Contents/Frameworks/Claude Helper.app", 0x20),
      record("\(data)/source/incoming.noindex/unpacked/Claude.app", 0x30),
      record("\(data)/source/3.1623.1.noindex/Claude.app", 0x40),
      record(outside.path, 0x50),
    ].joined(separator: "\n")
    let runner = lsregister(dump: dump)
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: runner)
    #expect(unregistered(runner, f) == [
      "source/3.1623.3.noindex/Claude.app",
      "source/3.1623.1.noindex/Claude.app",
      "source/3.1623.3.noindex/Claude.app/Contents/Frameworks/Claude Helper.app",
      "source/incoming.noindex/unpacked/Claude.app",
    ])
    #expect(f.updatesLog.contains("launchservices sweep: unregistered 4 of 4 (backups 0, staged 0, sources 1, database 3)"))
    #expect(FileManager.default.fileExists(atPath: sources.appendingPathComponent("3.1623.3.noindex/Claude.app/Contents").path))
  }

  /// `lsregister -u` on a bundle LaunchServices never registered fails with -10814 ("failed to scan … -10814"): that
  /// backup is already forgotten, not a failure.
  @Test func aBackupThatWasNeverRegisteredIsNotAFailure() async throws {
    let f = try fixture()
    try makeBundle(f.paths.backupDir.appendingPathComponent("Claude Home.app.20260101-000000"))
    let runner = ScriptedRunner { request in
      if request.arguments.first == "-dump" { return .ok(stdout: "") }
      return .fail(1, stderr: "lsregister: failed to scan \(request.arguments.last ?? ""): -10814\n")
    }
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: runner)
    let log = f.updatesLog
    #expect(log.contains("launchservices sweep: unregistered 0 of 1 (backups 1, staged 0, sources 0, database 0); 1 not registered"))
    #expect(!log.contains("failed"))
  }

  @Test func aFailedUnregisterOrDumpOnlyShowsInTheOneSummaryLine() async throws {
    let f = try fixture()
    try makeBundle(f.paths.backupDir.appendingPathComponent("Claude Home.app.20260101-000000"))
    let runner = lsregister(dumpExit: 1, unregisterExit: 1)
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: runner)
    #expect(unregistered(runner, f) == ["backup/Claude Home.app.20260101-000000"])
    let log = f.updatesLog
    #expect(log.contains("[updates] launchservices sweep: unregistered 0 of 1 (backups 1, staged 0, sources 0, database 0)"))
    #expect(log.contains("dump: lsregister exited 1"))
    #expect(log.contains("failed 1: Claude Home.app.20260101-000000"))
    #expect(log.split(separator: "\n").count == 1)
  }

  @Test func sweepIsIdempotentAndDeletesNothing() async throws {
    let f = try fixture()
    let home = f.paths.backupDir.appendingPathComponent("Claude Home.app.20260101-000000")
    try makeBundle(home)
    let first = lsregister()
    let second = lsregister()
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: first)
    await LaunchServicesCleanup.sweep(paths: f.paths, runner: second)
    #expect(first.commandLines == second.commandLines)
    #expect(first.commandLines.count == 2)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("Contents/Info.plist.disabled").path))
  }

  @Test func aFreshDataFolderOnlyReadsTheDatabase() async throws {
    let root = try makeTempDir()
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let runner = lsregister()
    await LaunchServicesCleanup.sweep(paths: paths, runner: runner)
    #expect(runner.commandLines == [["lsregister", "-dump", "Bundle"]])
  }

  @Test func dumpPathsKeepSpacesParenthesesAndUnicode() {
    let helper = "/Users/u/Library/Application Support/ClaudeMultiAcc/backup/Claude 5x акк.app.20261019-185659"
      + "/Contents/Frameworks/Claude Helper (GPU).app"
    let dump = """
      bundle id:                  Claude (0x6d68)
      path:                       \(helper) (0x96a0)
      path:                       /Applications/Claude.app (0x7018)
      path:                       /no/record/id.app
      path: relative/x.app (0x1)
        path:                     /indented/Not.app (0x2)
      directory:                  ~/Library
      """
    #expect(LaunchServicesCleanup.registeredPaths(inDump: Data(dump.utf8)) == [helper, "/Applications/Claude.app"])
  }
}
