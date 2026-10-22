import Foundation
import Testing
@testable import Support

/// Collects event paths from the FSEvents callback queue.
private final class EventSink: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [URL] = []
  var names: [String] { lock.withLock { storage.map(\.lastPathComponent) } }
  func add(_ urls: [URL]) { lock.withLock { storage.append(contentsOf: urls) } }
}

@Suite struct DirectoryWatcherTests {
  private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }

  @Test func reportsFileWritesInWatchedDirectory() async throws {
    let dir = try makeTempDir()
    let sink = EventSink()
    let watcher = DirectoryWatcher(paths: [dir], latency: 0.1) { sink.add($0) }
    watcher.start()
    defer { watcher.stop() }
    try await Task.sleep(for: .milliseconds(300))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("plan-usage-history.json"))
    #expect(try await waitUntil { sink.names.contains("plan-usage-history.json") })
  }

  @Test func stoppedWatcherReportsNothing() async throws {
    let dir = try makeTempDir()
    let sink = EventSink()
    let watcher = DirectoryWatcher(paths: [dir], latency: 0.1) { sink.add($0) }
    watcher.start()
    watcher.stop()
    try Data("{}".utf8).write(to: dir.appendingPathComponent("instances.json"))
    try await Task.sleep(for: .milliseconds(600))
    #expect(sink.names.isEmpty)
  }

  @Test func startIsIdempotentAndEmptyPathsAreFine() async throws {
    let empty = DirectoryWatcher(paths: [], latency: 0.1) { _ in }
    empty.start()
    #expect(!empty.isRunning)
    let dir = try makeTempDir()
    let sink = EventSink()
    let watcher = DirectoryWatcher(paths: [dir], latency: 0.1) { sink.add($0) }
    watcher.start()
    watcher.start()
    #expect(watcher.isRunning)
    try await Task.sleep(for: .milliseconds(300))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("once.json"))
    #expect(try await waitUntil { sink.names.contains("once.json") })
    try await Task.sleep(for: .milliseconds(300))
    // One stream, so the write is reported once, not once per `start`.
    #expect(sink.names.filter { $0 == "once.json" }.count == 1)
    watcher.stop()
    watcher.stop()
    #expect(!watcher.isRunning)
  }
}
