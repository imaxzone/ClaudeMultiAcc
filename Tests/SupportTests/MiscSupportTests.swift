import Foundation
import OSLog
import Testing
@testable import Support

@Suite struct MiscSupportTests {
  @Test func buildInfo() {
    #expect(BuildInfo.bundleId == "com.imaxzone.ClaudeMultiAcc")
  }

  /// `BuildInfo.version` is typed by hand: it must match the repo's `VERSION` file (the bundle's version), so the two
  /// cannot drift. `VERSION` is read from the package root, three levels above this file.
  @Test func buildInfoVersionMatchesTheVersionFile() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(!version.isEmpty)
    #expect(BuildInfo.version == version)
  }

  @Test func systemClockIsNow() {
    let delta = abs(SystemClock().now.timeIntervalSinceNow)
    #expect(delta < 5)
  }

  @Test func artifactsDirFallsBackToTemp() {
    let url = ArtifactsDir.url(environment: [:])
    #expect(url == FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeMultiAcc-artifacts", isDirectory: true))
  }

  @Test func artifactsDirHonoursEnvironment() {
    #expect(ArtifactsDir.url(environment: ["CMACC_ARTIFACTS_DIR": "/x/art"]).path == "/x/art")
  }

  /// The logger writes under our subsystem and the given category: read the entry back from the unified log.
  @Test func appLogWritesUnderOurSubsystemAndCategory() throws {
    let marker = "logger-smoke-\(UUID().uuidString)"
    AppLog.logger("tests").notice("\(marker, privacy: .public)")
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let since = store.position(date: Date().addingTimeInterval(-60))
    let entries = try store.getEntries(at: since, matching: NSPredicate(format: "subsystem == %@", AppLog.subsystem))
      .compactMap { $0 as? OSLogEntryLog }
      .filter { $0.composedMessage == marker }
    #expect(entries.count == 1)
    #expect(entries.first?.category == "tests")
    #expect(AppLog.subsystem == "com.imaxzone.ClaudeMultiAcc")
  }
}
