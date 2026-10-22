import Foundation
import InstanceBuilder
import Support
import Synchronization
import Testing
@testable import UI

/// Answers each tool with its exit code from `exits` (0 otherwise) and records the command line together with what
/// `probe` saw at that moment (the file state the step found); runs nothing.
final class DockStepRunner: ProcessRunning {
  private let lines = Mutex<[String]>([])
  let exits: [String: Int32]
  let probe: @Sendable () -> String

  init(exits: [String: Int32] = [:], probe: @escaping @Sendable () -> String = { "" }) {
    self.exits = exits
    self.probe = probe
  }

  var steps: [String] { lines.withLock { $0 } }

  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    let command = ([request.executable.path] + request.arguments).joined(separator: " ")
    let state = probe()
    lines.withLock { $0.append(state.isEmpty ? command : "\(command) [\(state)]") }
    let code = exits[request.executable.lastPathComponent] ?? 0
    return ProcessResult(exitCode: code, stdout: Data(), stderr: Data("failed".utf8), timedOut: false)
  }
}

/// A clone in a temp `Applications` folder with old modification dates, and a temp folder standing in for the
/// per-user cache dir. Never the real cache dir, Dock or LaunchServices.
struct DockFixture: Sendable {
  static let old = Date(timeIntervalSince1970: 1_000_000_000)
  static let lsregister =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

  let root: URL
  let app: URL
  let plist: URL
  let cacheDir: URL
  var cacheFile: URL { cacheDir.appendingPathComponent("com.apple.dock.iconcache") }

  init(_ name: String = #function) throws {
    let fm = FileManager.default
    root = try makeTempDir(name)
    app = root.appendingPathComponent("Applications/Claude Work.app", isDirectory: true)
    plist = app.appendingPathComponent("Contents/Info.plist")
    try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("<plist/>".utf8).write(to: plist)
    for url in [plist, app] { try fm.setAttributes([.modificationDate: Self.old], ofItemAtPath: url.path) }
    cacheDir = root.appendingPathComponent("C", isDirectory: true)
    try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
  }

  func writeCacheFile() throws {
    try Data(repeating: 7, count: 64).write(to: cacheFile)
  }

  /// The modification date moved forward (to now).
  func touched(_ url: URL) -> Bool {
    let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    return (date ?? Self.old) > Self.old.addingTimeInterval(86_400)
  }

  /// lstat: something is at `url` itself (a symlink counts, whatever it points to).
  static func present(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }

  /// What a step saw: whether the bundle and its Info.plist were touched, and whether the cache file is there.
  var probe: @Sendable () -> String {
    { [self] in
      let touch = touched(app) && touched(plist) ? "touched" : "untouched"
      return "\(touch), cache \(Self.present(cacheFile) ? "present" : "gone")"
    }
  }

  func refresh(_ runner: DockStepRunner, staging: StagingArea? = nil, cacheDir: URL?? = nil)
    -> InstanceEditorRefreshDock {
    let dir = cacheDir ?? self.cacheDir
    return InstanceEditorDock.restart(runner: runner, staging: staging, cacheDirectory: { dir })
  }
}

/// The live «Обновить Док»: touch the clone, `lsregister -f` it, remove the Dock's own icon cache file (that file
/// only, never through a symlink), then `killall Dock`. Every step but the last only logs a failure.
@Suite struct InstanceEditorDockTests {
  @Test func theStepsRunInOrderTouchRegisterCacheThenDock() async throws {
    let f = try DockFixture()
    try f.writeCacheFile()
    let runner = DockStepRunner(probe: f.probe)
    try await f.refresh(runner)([f.app])
    #expect(runner.steps == [
      "\(DockFixture.lsregister) -f \(f.app.path) [touched, cache present]",
      "/usr/bin/killall Dock [touched, cache gone]",
    ])
  }

  @Test func onlyTheExactCacheFileIsRemoved() async throws {
    let f = try DockFixture()
    try f.writeCacheFile()
    let fm = FileManager.default
    let siblings = ["com.apple.dock.iconcache.bak", "com.apple.dock.iconcache-journal", "com.apple.dock.extra"]
      .map { f.cacheDir.appendingPathComponent($0) }
    for url in siblings { try Data("keep".utf8).write(to: url) }
    let iconServices = f.cacheDir.appendingPathComponent("com.apple.iconservices", isDirectory: true)
    try fm.createDirectory(at: iconServices, withIntermediateDirectories: true)
    try Data("index".utf8).write(to: iconServices.appendingPathComponent("store.index"))

    try await f.refresh(DockStepRunner())([f.app])

    #expect(!DockFixture.present(f.cacheFile))
    #expect(siblings.allSatisfy(DockFixture.present))
    #expect(DockFixture.present(iconServices.appendingPathComponent("store.index")))
    #expect(try fm.contentsOfDirectory(atPath: f.cacheDir.path).sorted()
      == ["com.apple.dock.extra", "com.apple.dock.iconcache-journal", "com.apple.dock.iconcache.bak",
          "com.apple.iconservices"])
  }

  /// A symlink at the cache path is neither followed nor removed; the Dock still restarts.
  @Test func aSymlinkAtTheCachePathIsLeftAlone() async throws {
    let f = try DockFixture()
    let target = f.root.appendingPathComponent("precious.txt")
    try Data("precious".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: f.cacheFile, withDestinationURL: target)
    let runner = DockStepRunner(probe: f.probe)

    try await f.refresh(runner)([f.app])

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.cacheFile.path) == target.path)
    #expect(try Data(contentsOf: target) == Data("precious".utf8))
    #expect(runner.steps.last == "/usr/bin/killall Dock [touched, cache present]")
  }

  /// A folder at the cache path is not a regular file: left alone with what is inside.
  @Test func aFolderAtTheCachePathIsLeftAlone() async throws {
    let f = try DockFixture()
    try FileManager.default.createDirectory(at: f.cacheFile, withIntermediateDirectories: true)
    let inside = f.cacheFile.appendingPathComponent("inside")
    try Data("x".utf8).write(to: inside)

    try await f.refresh(DockStepRunner())([f.app])

    #expect(DockFixture.present(inside))
  }

  @Test func aMissingCacheFileIsFine() async throws {
    let f = try DockFixture()
    let runner = DockStepRunner(probe: f.probe)
    try await f.refresh(runner)([f.app])
    #expect(runner.steps == [
      "\(DockFixture.lsregister) -f \(f.app.path) [touched, cache gone]",
      "/usr/bin/killall Dock [touched, cache gone]",
    ])
  }

  /// The bundle is gone (no touch), `lsregister` fails and there is no cache dir: the Dock still restarts.
  @Test func failedEarlyStepsStillRestartTheDock() async throws {
    let f = try DockFixture()
    try f.writeCacheFile()
    let gone = f.root.appendingPathComponent("Applications/Gone.app", isDirectory: true)
    let runner = DockStepRunner(exits: ["lsregister": 1])

    try await f.refresh(runner, cacheDir: .some(nil))([gone])

    #expect(runner.steps == ["\(DockFixture.lsregister) -f \(gone.path)", "/usr/bin/killall Dock"])
    #expect(!FileManager.default.fileExists(atPath: gone.path))
    #expect(DockFixture.present(f.cacheFile))
  }

  /// A cache dir that does not exist is only logged too.
  @Test func aMissingCacheDirStillRestartsTheDock() async throws {
    let f = try DockFixture()
    let runner = DockStepRunner()
    try await f.refresh(runner, cacheDir: f.root.appendingPathComponent("nowhere", isDirectory: true))([f.app])
    #expect(runner.steps.last == "/usr/bin/killall Dock")
  }

  /// Only the Dock restart decides the outcome: a non-zero `killall` is an error the button shows.
  @Test func aFailedDockRestartIsAnError() async throws {
    let f = try DockFixture()
    try f.writeCacheFile()
    let runner = DockStepRunner(exits: ["killall": 1])
    await #expect(throws: InstanceEditorDockError.failed(exitCode: 1)) {
      try await f.refresh(runner)([f.app])
    }
    #expect(runner.steps == ["\(DockFixture.lsregister) -f \(f.app.path)", "/usr/bin/killall Dock"])
  }

  /// No app known: only the cache file and the Dock.
  @Test func withoutAnAppOnlyTheCacheAndTheDockAreRefreshed() async throws {
    let f = try DockFixture()
    try f.writeCacheFile()
    let runner = DockStepRunner(probe: f.probe)
    try await f.refresh(runner)([])
    #expect(runner.steps == ["/usr/bin/killall Dock [untouched, cache gone]"])
  }

  /// A staged bundle is never touched or registered (G12).
  @Test func aStagedBundleIsNeitherTouchedNorRegistered() async throws {
    let f = try DockFixture()
    let paths = Paths(home: f.root, dataDir: f.root.appendingPathComponent("data", isDirectory: true))
    let staged = paths.stagingDir
      .appendingPathComponent("work-20261022-120000.noindex/Claude Work.app", isDirectory: true)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.modificationDate: DockFixture.old], ofItemAtPath: staged.path)
    let runner = DockStepRunner()

    try await f.refresh(runner, staging: StagingArea(paths: paths))([staged])

    #expect(runner.steps == ["/usr/bin/killall Dock"])
    #expect(!f.touched(staged))
  }

  /// The live cache dir comes from `confstr(_CS_DARWIN_USER_CACHE_DIR)` (read only here).
  @Test func theUserCacheDirIsTheDarwinOne() throws {
    let dir = try #require(InstanceEditorDock.darwinUserCacheDirectory())
    var isDirectory: ObjCBool = false
    #expect(dir.path.hasPrefix("/") && dir.path.hasSuffix("/C"))
    #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory) && isDirectory.boolValue)
  }
}
