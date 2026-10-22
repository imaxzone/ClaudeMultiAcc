import Foundation
import Testing
@testable import Support

@Suite struct ReleaseStateTests {
  private func sampleState() throws -> ReleaseCheckState {
    let page = try #require(URL(string: ReleaseFixture.page))
    return ReleaseCheckState(
      lastCheck: ReleaseFixture.start, etag: "W/\"abc\"",
      latest: ReleaseCheckState.Release(version: "1.2.0", pageURL: page))
  }

  @Test func roundTripsThroughAPrivateFile() throws {
    let file = try makeTempDir().appendingPathComponent("release-check.json")
    let store = ReleaseStateStore(file: file)
    let state = try sampleState()
    store.save(state)
    #expect(store.load() == state)
    #expect(try posixPermissions(file) == 0o600)
  }

  @Test func writesStableReadableJSON() throws {
    let file = try makeTempDir().appendingPathComponent("release-check.json")
    ReleaseStateStore(file: file).save(try sampleState())
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains(#""lastCheck" : "2026-09-21T14:13:20Z""#))
    #expect(text.contains(#""etag" : "W/\"abc\"""#))
    #expect(text.contains(#""pageURL" : "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/v1.2.0""#))
    #expect(text.contains(#""version" : "1.2.0""#))
  }

  @Test func missingFileReadsAsEmpty() throws {
    let file = try makeTempDir().appendingPathComponent("absent.json")
    #expect(ReleaseStateStore(file: file).load() == .empty)
  }

  @Test func corruptFileReadsAsEmptyAndIsReplacedOnSave() throws {
    let file = try makeTempDir().appendingPathComponent("release-check.json")
    try Data("{ nope".utf8).write(to: file)
    let store = ReleaseStateStore(file: file)
    #expect(store.load() == .empty)
    let state = try sampleState()
    store.save(state)
    #expect(store.load() == state)
  }

  @Test func partialFileKeepsWhatItHas() throws {
    let file = try makeTempDir().appendingPathComponent("release-check.json")
    try Data(#"{"lastCheck":"2026-09-21T14:13:20Z"}"#.utf8).write(to: file)
    let state = ReleaseStateStore(file: file).load()
    #expect(state.lastCheck == ReleaseFixture.start)
    #expect(state.etag == nil)
    #expect(state.latest == nil)
  }

  @Test func saveCreatesTheDataDir() throws {
    let file = try makeTempDir().appendingPathComponent("nested/data/release-check.json")
    ReleaseStateStore(file: file).save(.empty)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }

  @Test func livesInTheAppDataDir() {
    let paths = Paths(home: URL(fileURLWithPath: "/Users/x", isDirectory: true))
    #expect(paths.releaseCheckFile.path == "/Users/x/Library/Application Support/ClaudeMultiAcc/release-check.json")
  }

  @Test func updatesAreCopies() throws {
    let state = try sampleState()
    let checked = state.with(lastCheck: ReleaseFixture.start.addingTimeInterval(5))
    #expect(checked.lastCheck == ReleaseFixture.start.addingTimeInterval(5))
    #expect(checked.latest == state.latest)
    let cleared = state.with(etag: nil, latest: nil)
    #expect(cleared.lastCheck == state.lastCheck)
    #expect(cleared.latest == nil)
    #expect(state.etag == "W/\"abc\"")
  }
}
