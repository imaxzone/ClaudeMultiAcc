import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

@Suite(.russian) struct TranslocationCheckTests {
  static let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)

  @Test(arguments: [
    "/private/var/folders/x1/abcd1234/T/AppTranslocation/AAAAAAAA-0000-4000-8000-000000000001/d/ClaudeMultiAcc.app",
    "/var/folders/x1/abcd1234/T/AppTranslocation/AAAAAAAA-0000-4000-8000-000000000001/d/ClaudeMultiAcc.app",
  ])
  func translocatedPaths(_ path: String) {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    #expect(TranslocationCheck.isTranslocated(url))
    #expect(TranslocationCheck.location(of: url, home: Self.home) == .translocated)
  }

  @Test(arguments: [
    "/Applications/ClaudeMultiAcc.app",
    "/Users/u/Applications/ClaudeMultiAcc.app",
    "/Users/u/Downloads/ClaudeMultiAcc.app",
    "/Users/u/AppTranslocation/5E7C/d/ClaudeMultiAcc.app",
    "/private/var/folders/x1/abcd1234/T/AppTranslocation",
    "/private/var/folders/x1/abcd1234/T/NotAppTranslocation/5E7C/d/ClaudeMultiAcc.app",
  ])
  func ordinaryPaths(_ path: String) {
    #expect(!TranslocationCheck.isTranslocated(URL(fileURLWithPath: path, isDirectory: true)))
  }

  /// R2 item 4 / R3: only `/Applications` and `~/Applications` (subfolders too) count as installed.
  @Test(arguments: [
    ("/Applications/ClaudeMultiAcc.app", AppLocation.applications),
    ("/Applications/Utilities/ClaudeMultiAcc.app", .applications),
    ("/Users/u/Applications/ClaudeMultiAcc.app", .applications),
    ("/Users/u/Applications/../Downloads/ClaudeMultiAcc.app", .elsewhere),
    ("/Users/u/Downloads/ClaudeMultiAcc.app", .elsewhere),
    ("/Users/u/Documents/GitHub/ClaudeMultiAcc/dist/ClaudeMultiAcc.app", .elsewhere),
    ("/Volumes/ClaudeMultiAcc/ClaudeMultiAcc.app", .elsewhere),
    ("/Users/x/Applications/ClaudeMultiAcc.app", .elsewhere),
    ("/Applications", .elsewhere),
    ("/ApplicationsX/ClaudeMultiAcc.app", .elsewhere),
  ])
  func locations(_ path: String, _ expected: AppLocation) {
    let location = TranslocationCheck.location(of: URL(fileURLWithPath: path, isDirectory: true), home: Self.home)
    #expect(location == expected, "\(path)")
    #expect(location.offersMove == (expected != .applications))
  }

  @Test func liveCheckOfAnOrdinaryDirectoryIsFalse() throws {
    let dir = try makeTempDir()
    #expect(!TranslocationCheck.isTranslocatedLive(dir))
    #expect(TranslocationCheck.originalURL(of: dir) == nil)
    #expect(TranslocationCheck.liveLocation(of: dir, home: Self.home) == .elsewhere)
    #expect(TranslocationCheck.liveLocation(of: URL(fileURLWithPath: "/Applications/Nope-\(UUID()).app"), home: Self.home)
      == .applications)
  }

  @Test func destinationIsSystemApplicationsWhenWritable() {
    #expect(ApplicationsMover.destinationDirectory(home: Self.home) { $0 == "/Applications" }.path == "/Applications")
    #expect(ApplicationsMover.destinationDirectory(home: Self.home) { _ in false }.path == "/Users/u/Applications")
  }

  @Test func installCopiesWithoutQuarantineAndTrashesAnOlderCopy() throws {
    let root = try makeTempDir()
    let source = try makeQuarantinedApp(in: root.appendingPathComponent("Downloads", isDirectory: true))
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    try writeInfo(applications.appendingPathComponent("ClaudeMultiAcc.app"), id: BuildInfo.bundleId, version: "0.0.1")
    let effects = Effects()
    let installed = try effects.mover(home: root).install(source, into: applications)
    #expect(installed.path == applications.appendingPathComponent("ClaudeMultiAcc.app").path)
    #expect(effects.trashed == [installed.path])
    #expect(try Data(contentsOf: installed.appendingPathComponent("Contents/MacOS/ClaudeMultiAcc")) == MiniBundle.machOBytes)
    #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Info.plist").path))
    expectNoQuarantine(in: installed)
    #expect(Quarantine.isSet(on: source), "the original is left as it is")
  }

  @Test func moveAndRelaunchDoesNothingInApplications() throws {
    let effects = Effects()
    for running in ["/Applications/ClaudeMultiAcc.app", "/Users/u/Applications/ClaudeMultiAcc.app"] {
      let mover = effects.mover(home: Self.home, destination: URL(fileURLWithPath: "/nonexistent", isDirectory: true))
      #expect(try mover.moveAndRelaunch(running: URL(fileURLWithPath: running, isDirectory: true)) == nil)
    }
    #expect(effects.trashed.isEmpty && effects.relaunched.isEmpty)
  }

  /// Started from «Загрузки» without translocation (quarantine already gone): the copy goes to «Программы», the
  /// original to the Trash, and the relauncher opens the copy.
  @Test func moveAndRelaunchMovesAnAppStartedElsewhere() throws {
    let root = try makeTempDir()
    let source = try makeQuarantinedApp(in: root.appendingPathComponent("Downloads", isDirectory: true))
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let effects = Effects()
    let moved = try effects.mover(home: root, destination: applications).moveAndRelaunch(running: source)
    let target = applications.appendingPathComponent("ClaudeMultiAcc.app")
    #expect(moved?.path == target.path)
    #expect(effects.trashed == [source.path])
    #expect(effects.relaunched == [target.path])
    expectNoQuarantine(in: target)
  }

  @Test func failedTrashStillRelaunchesTheCopy() throws {
    let root = try makeTempDir()
    let source = try makeQuarantinedApp(in: root.appendingPathComponent("Volumes/Disk", isDirectory: true))
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let effects = Effects(trashFails: true)
    let moved = try effects.mover(home: root, destination: applications).moveAndRelaunch(running: source)
    #expect(moved?.path == applications.appendingPathComponent("ClaudeMultiAcc.app").path)
    #expect(FileManager.default.fileExists(atPath: source.path), "a read-only original stays where it is")
    #expect(effects.relaunched.count == 1)
  }

  /// L9: an app of the same name that is not ClaudeMultiAcc (or a link) is never trashed to make room.
  @Test(arguments: [("com.example.other", "1.0.0"), ("", "")])
  func installRefusesToReplaceAnotherApp(id: String, version: String) throws {
    let root = try makeTempDir()
    let source = try makeQuarantinedApp(in: root.appendingPathComponent("Downloads", isDirectory: true))
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let existing = applications.appendingPathComponent("ClaudeMultiAcc.app")
    if id.isEmpty {
      try MiniBundle.write(Data("x".utf8), existing.appendingPathComponent("Contents/MacOS/other"))
    } else {
      try writeInfo(existing, id: id, version: version)
    }
    let effects = Effects()
    #expect(throws: TranslocationError.foreignAppInTheWay(existing.path)) {
      _ = try effects.mover(home: root).install(source, into: applications)
    }
    #expect(effects.trashed.isEmpty && FileManager.default.fileExists(atPath: existing.appendingPathComponent("Contents").path))
  }

  @Test func installRefusesALinkInTheWay() throws {
    let root = try makeTempDir()
    let source = try makeQuarantinedApp(in: root.appendingPathComponent("Downloads", isDirectory: true))
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let ours = root.appendingPathComponent("elsewhere/ClaudeMultiAcc.app")
    try writeInfo(ours, id: BuildInfo.bundleId, version: "0.0.1")
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    let link = applications.appendingPathComponent("ClaudeMultiAcc.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ours)
    let effects = Effects()
    #expect(throws: TranslocationError.foreignAppInTheWay(link.path)) {
      _ = try effects.mover(home: root).install(source, into: applications)
    }
    #expect(effects.trashed.isEmpty)
  }

  /// Code review M6: a newer ClaudeMultiAcc already in «Программы» is never replaced by an older download.
  @Test func installRefusesToReplaceANewerCopy() throws {
    let root = try makeTempDir()
    let source = try makeQuarantinedApp(in: root.appendingPathComponent("Downloads", isDirectory: true))
    try writeInfo(source, id: BuildInfo.bundleId, version: "1.2.0")
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let existing = applications.appendingPathComponent("ClaudeMultiAcc.app")
    try writeInfo(existing, id: BuildInfo.bundleId, version: "1.10.0")
    let effects = Effects()
    #expect(throws: TranslocationError.newerCopyInstalled(installed: "1.10.0", running: "1.2.0")) {
      _ = try effects.mover(home: root).install(source, into: applications)
    }
    #expect(effects.trashed.isEmpty)
    try writeInfo(existing, id: BuildInfo.bundleId, version: "1.2.0")
    _ = try effects.mover(home: root).install(source, into: applications)
    #expect(effects.trashed == [existing.path])
  }

  @Test func refusalsHaveRussianMessages() {
    for error in [TranslocationError.foreignAppInTheWay("/Applications/ClaudeMultiAcc.app"),
                  .newerCopyInstalled(installed: "1.10.0", running: "1.2.0")] {
      let message = UserMessage.text(for: error)
      #expect(message.range(of: "[А-Яа-я]", options: .regularExpression) != nil)
      #expect(!message.contains("com.") && !message.contains("("))
    }
    #expect(TranslocationError.newerCopyInstalled(installed: "1.10.0", running: "1.2.0").userMessage.contains("1.10.0"))
  }

  /// L9: the relauncher waits for the old process at most `attempts` × 0.2 s (a pid that never exits or was reused),
  /// then opens the copy anyway. `/usr/bin/touch` stands in for `open`.
  @Test func theRelaunchWaitIsCapped() throws {
    let root = try makeTempDir()
    let marker = root.appendingPathComponent("opened")
    let started = Date()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ApplicationsMover.relaunchArguments(app: marker, pid: getpid(), attempts: 3, opener: "/usr/bin/touch")
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let waited = Date().timeIntervalSince(started)
    #expect(waited >= 0.5 && waited < 10, "\(waited)")
  }

  @Test func theLiveRelaunchWaitsAboutAMinuteForTheOldProcessThenOpens() {
    let arguments = ApplicationsMover.relaunchArguments(app: URL(fileURLWithPath: "/Applications/ClaudeMultiAcc.app"), pid: 42)
    #expect(arguments.suffix(4) == ["42", "/Applications/ClaudeMultiAcc.app", "300", "/usr/bin/open"])
    #expect(Double(ApplicationsMover.relaunchAttempts) * 0.2 == 60)
    #expect(arguments.first == "-c" && arguments[1].contains("-lt \"$3\""))
  }

  private func writeInfo(_ app: URL, id: String, version: String) throws {
    let info = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version], format: .xml, options: 0)
    try MiniBundle.write(info, app.appendingPathComponent("Contents/Info.plist"))
  }

  private func makeQuarantinedApp(in dir: URL) throws -> URL {
    let app = dir.appendingPathComponent("ClaudeMultiAcc.app", isDirectory: true)
    let binary = app.appendingPathComponent("Contents/MacOS/ClaudeMultiAcc")
    try MiniBundle.write(MiniBundle.machOBytes, binary, mode: 0o755)
    let helper = app.appendingPathComponent("Contents/Helpers/CloneLauncher")
    try MiniBundle.write(MiniBundle.machOBytes, helper, mode: 0o755)
    for url in [app, binary, helper] { try addQuarantine(url) }
    return app
  }

  private func expectNoQuarantine(in app: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    for relative in ["", "Contents/MacOS/ClaudeMultiAcc", "Contents/Helpers/CloneLauncher"] {
      #expect(!Quarantine.isSet(on: app.appendingPathComponent(relative)), "quarantined: \(relative)",
              sourceLocation: sourceLocation)
    }
  }
}

/// Fake Trash and relauncher: the real ones are never used in tests.
private final class Effects: Sendable {
  private let log = Mutex<(trashed: [String], relaunched: [String])>(([], []))
  private let trashFails: Bool

  init(trashFails: Bool = false) {
    self.trashFails = trashFails
  }

  var trashed: [String] { log.withLock { $0.trashed } }
  var relaunched: [String] { log.withLock { $0.relaunched } }

  func mover(home: URL, destination: URL? = nil) -> ApplicationsMover {
    ApplicationsMover(
      home: home, destination: destination,
      trash: { [self] url in
        if trashFails { throw CocoaError(.fileWriteVolumeReadOnly) }
        log.withLock { $0.trashed.append(url.path) }
        try FileManager.default.removeItem(at: url)
      },
      relaunch: { [self] url in log.withLock { $0.relaunched.append(url.path) } })
  }
}
