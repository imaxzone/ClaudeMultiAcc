import Foundation
import Testing
@testable import Support

@Suite struct AtomicFileTests {
  @Test func writesContentWithDefaultPermissions() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("a.json")
    try AtomicFile.write(Data("hello".utf8), to: url)
    #expect(try Data(contentsOf: url) == Data("hello".utf8))
    #expect(try posixPermissions(url) == 0o644)
  }

  @Test func honoursPermissions() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("secret.json")
    try AtomicFile.write(Data("x".utf8), to: url, permissions: 0o600)
    #expect(try posixPermissions(url) == 0o600)
  }

  @Test func overwriteReplacesAndLeavesNoTempFiles() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("s.json")
    try AtomicFile.write(Data("first-long-content".utf8), to: url)
    try AtomicFile.write(Data("2nd".utf8), to: url, permissions: 0o600)
    #expect(try Data(contentsOf: url) == Data("2nd".utf8))
    #expect(try posixPermissions(url) == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["s.json"])
  }

  @Test func readersSeeOnlyCompleteVersions() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("r.txt")
    let versions = (0..<50).map { Data(String(repeating: "\($0 % 10)", count: 4096 + $0).utf8) }
    try AtomicFile.write(versions[0], to: url)
    let valid = Set(versions)
    let writer = Task.detached {
      for v in versions { try AtomicFile.write(v, to: url) }
    }
    for _ in 0..<200 {
      let seen = try Data(contentsOf: url)
      #expect(valid.contains(seen))
    }
    try await writer.value
  }

  @Test func missingParentDirectoryIsCreated() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("sub/deeper/f.txt")
    try AtomicFile.write(Data("x".utf8), to: url)
    #expect(try Data(contentsOf: url) == Data("x".utf8))
  }
}
