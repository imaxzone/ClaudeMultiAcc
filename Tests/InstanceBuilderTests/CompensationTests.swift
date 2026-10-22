import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// A `FileMover` that fails the renames a test picks (by call number, 1-based) and records every attempt.
final class ScriptedMover: Sendable {
  private let failing: Set<Int>
  private let calls = Mutex<[String]>([])

  init(failing: Set<Int>) {
    self.failing = failing
  }

  var attempts: [String] { calls.withLock { $0 } }

  var mover: FileMover {
    FileMover { [self] from, to in
      let n = calls.withLock { list -> Int in
        list.append("\(from.lastPathComponent)→\(to.lastPathComponent)")
        return list.count
      }
      if failing.contains(n) { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.moveItem(at: from, to: to)
    }
  }
}

/// Undo steps are never silent: a failed compensation names where the bundle ended up (S5).
@Suite struct CompensationTests {
  static let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func makeApp(_ url: URL, marker: String) throws {
    try MiniBundle.write(Data("<plist>\(marker)</plist>".utf8), url.appendingPathComponent("Contents/Info.plist"))
    try MiniBundle.write(Data(marker.utf8), url.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
  }

  private func marker(_ app: URL) -> String? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Claude"))).map { String(decoding: $0, as: UTF8.self) }
  }

  /// Calls: 1 live→backup, 2 disable plist, 3 staged→live (fails), 4 enable plist, 5 backup→live (fails).
  @Test func swapReportsWhereTheOldAppWasLeftWhenTheUndoFails() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    let staged = root.appendingPathComponent("staged/Claude 2nd.app")
    try makeApp(live, marker: "old")
    try makeApp(staged, marker: "new")
    let backupDir = root.appendingPathComponent("backup")
    let scripted = ScriptedMover(failing: [3, 5])
    let backup = backupDir.appendingPathComponent("Claude 2nd.app.20260921-141320")
    do {
      _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: backupDir, now: Self.now, timeZone: .gmt,
                                 mover: scripted.mover)
      Issue.record("swap must throw")
    } catch let SwapError.compensationFailed(original, leftAt) {
      #expect(leftAt == backup.path)
      #expect(!original.isEmpty)
    }
    #expect(scripted.attempts.count == 5)
    #expect(marker(backup) == "old")
    #expect(SwapError.compensationFailed(original: "x", leftAt: "/b/app").description.contains("/b/app"))
  }

  @Test func swapUndoStillSucceedsSilentlyWhenEveryUndoStepWorks() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let live = root.appendingPathComponent("Applications/Claude 2nd.app")
    let staged = root.appendingPathComponent("staged/Claude 2nd.app")
    try makeApp(live, marker: "old")
    try makeApp(staged, marker: "new")
    let scripted = ScriptedMover(failing: [3])
    #expect(throws: CocoaError(.fileWriteNoPermission)) {
      _ = try BundleSwapper.swap(live: live, staged: staged, backupDir: root.appendingPathComponent("backup"),
                                 now: Self.now, timeZone: .gmt, mover: scripted.mover)
    }
    #expect(marker(live) == "old")
    #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("Contents/Info.plist").path))
  }
}
