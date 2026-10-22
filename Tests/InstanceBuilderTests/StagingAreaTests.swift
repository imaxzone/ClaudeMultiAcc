import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite struct StagingAreaTests {
  let date = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13:20 UTC

  private func area(_ root: URL) -> StagingArea {
    StagingArea(paths: Paths(home: root, dataDir: root.appendingPathComponent("data")), timeZone: TimeZone(identifier: "UTC"))
  }

  @Test func newBuildDirIsNoindexAndPrivate() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = try area(root).newBuildDir(slug: testSlug("stagetest"), now: date)
    #expect(dir.lastPathComponent == "stagetest-20260921-141320.noindex")
    #expect(dir.deletingLastPathComponent().standardizedFileURL.path
      == root.appendingPathComponent("data/staging").standardizedFileURL.path)
    let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o700)
    #expect(throws: BuilderError.self) { try area(root).newBuildDir(slug: testSlug("stagetest"), now: date) }
  }

  @Test func buildsListsOnlyThatSlug() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = area(root)
    let a = try staging.newBuildDir(slug: testSlug("test"), now: date)
    let b = try staging.newBuildDir(slug: testSlug("test"), now: date.addingTimeInterval(60))
    _ = try staging.newBuildDir(slug: testSlug("test-2"), now: date)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("data/staging/test-other.noindex"), withIntermediateDirectories: true)
    #expect(try staging.builds(slug: testSlug("test")).map(\.lastPathComponent) == [a.lastPathComponent, b.lastPathComponent])
    #expect(try staging.builds(slug: testSlug("test-2")).count == 1)
    #expect(try staging.builds(slug: testSlug("none")).isEmpty)
  }

  @Test func discardRemovesAllBuildsOfSlug() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = area(root)
    let dir = try staging.newBuildDir(slug: testSlug("stagetest"), now: date)
    try MiniBundle.write(Data("x".utf8), dir.appendingPathComponent("Claude.app/Contents/Info.plist"))
    _ = try staging.newBuildDir(slug: testSlug("stagetest"), now: date.addingTimeInterval(1))
    let keep = try staging.newBuildDir(slug: testSlug("other"), now: date)
    #expect(try staging.discard(slug: testSlug("stagetest")) == 2)
    #expect(try staging.builds(slug: testSlug("stagetest")).isEmpty)
    #expect(FileManager.default.fileExists(atPath: keep.path))
    #expect(try staging.discard(slug: testSlug("stagetest")) == 0)
  }

  @Test func discardRefusesSymlinksAndDeletesNothing() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = area(root)
    let real = try staging.newBuildDir(slug: testSlug("stagetest"), now: date)
    let victim = root.appendingPathComponent("victim", isDirectory: true)
    try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("data/staging/stagetest-20260101-000000.noindex")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
    #expect(throws: BuilderError.stagingPathRefused(link.path)) { try staging.discard(slug: testSlug("stagetest")) }
    #expect(FileManager.default.fileExists(atPath: victim.path))
    #expect(FileManager.default.fileExists(atPath: real.path))
  }

  @Test func discardRefusesWhenStagingItselfIsASymlink() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("stagetest-20260101-000000.noindex"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/staging"), withDestinationURL: elsewhere)
    #expect(throws: BuilderError.self) { try area(root).discard(slug: testSlug("stagetest")) }
    #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("stagetest-20260101-000000.noindex").path))
  }

  @Test func ownsRecognisesPathsInsideStaging() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = area(root)
    let dir = try staging.newBuildDir(slug: testSlug("a"), now: date)
    #expect(staging.contains(dir.appendingPathComponent("Claude A.app")))
    #expect(!staging.contains(URL(fileURLWithPath: "/Applications/Claude.app")))
  }

  @Test func containsResolvesSymlinksIntoStaging() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = area(root)
    let dir = try staging.newBuildDir(slug: testSlug("a"), now: date)
    let link = root.appendingPathComponent("innocent-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
    #expect(staging.contains(link.appendingPathComponent("Claude A.app")))
  }
}
