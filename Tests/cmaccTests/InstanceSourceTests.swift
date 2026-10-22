import Foundation
import InstanceBuilder
import Support
import Testing
@testable import cmacc

/// Without `--source`, `cmacc instance build|verify|new` use the newest Claude: a download strictly newer than the
/// official app, else the official app (its path also when it is missing, as before downloads existed).
@Suite struct InstanceSourceTests {
  private func writeClaude(_ app: URL, version: String) throws {
    let info: [String: Any] = ["CFBundleIdentifier": CloneSpec.vendorBundleId, "CFBundleShortVersionString": version]
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
  }

  @Test func theDefaultSourceIsTheNewestClaude() throws {
    let root = TempDirs.register(FileManager.default.temporaryDirectory
      .appendingPathComponent("cmacc-cli-source-\(UUID().uuidString)", isDirectory: true))
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let official = root.appendingPathComponent("Applications/Claude.app", isDirectory: true)
    let download = paths.claudeSourcesDir.appendingPathComponent("3.1623.3.noindex/Claude.app", isDirectory: true)
    try writeClaude(download, version: "3.1623.3")
    #expect(InstanceCommand.defaultSource(paths, officialApp: official).path == official.path)
    try writeClaude(official, version: "3.1623.0")
    #expect(InstanceCommand.defaultSource(paths, officialApp: official).path == download.path)
    try writeClaude(official, version: "3.1623.3")
    #expect(InstanceCommand.defaultSource(paths, officialApp: official).path == official.path)
    #expect(InstanceCommand.officialApp.path == "/Applications/Claude.app")
  }
}
