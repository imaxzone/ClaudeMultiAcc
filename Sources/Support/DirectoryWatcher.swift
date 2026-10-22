import CoreServices
import Foundation

/// Watches directories with FSEvents (file-level events) and reports changed paths on a private serial queue.
/// `latency` is the FSEvents coalescing window, which doubles as the debounce interval.
public final class DirectoryWatcher: @unchecked Sendable {
  private let paths: [URL]
  private let latency: TimeInterval
  private let handler: @Sendable ([URL]) -> Void
  private let queue = DispatchQueue(label: "com.imaxzone.ClaudeMultiAcc.directory-watcher")
  private static let queueKey = DispatchSpecificKey<Bool>()
  private let lock = NSLock()
  private var stream: FSEventStreamRef?
  private let log = AppLog.logger("directory-watcher")

  public init(paths: [URL], latency: TimeInterval = 1.0, handler: @escaping @Sendable ([URL]) -> Void) {
    self.paths = paths
    self.latency = latency
    self.handler = handler
    queue.setSpecific(key: Self.queueKey, value: true)
  }

  deinit {
    stop()
  }

  /// Whether an FSEvents stream is running.
  public var isRunning: Bool { lock.withLock { stream != nil } }

  /// Starts watching; calling it again while running does nothing.
  public func start() {
    lock.withLock {
      guard stream == nil, !paths.isEmpty else { return }
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
      guard let created = FSEventStreamCreate(
        kCFAllocatorDefault, Self.callback, &context, paths.map(\.path) as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
      else {
        log.error("FSEventStreamCreate failed for \(self.paths.count, privacy: .public) paths")
        return
      }
      FSEventStreamSetDispatchQueue(created, queue)
      guard FSEventStreamStart(created) else {
        log.error("FSEventStreamStart failed")
        FSEventStreamInvalidate(created)
        FSEventStreamRelease(created)
        return
      }
      stream = created
    }
  }

  /// Stops watching; no callback runs after this returns.
  public func stop() {
    let current: FSEventStreamRef? = lock.withLock {
      defer { stream = nil }
      return stream
    }
    guard let current else { return }
    FSEventStreamStop(current)
    FSEventStreamInvalidate(current)
    FSEventStreamRelease(current)
    // Drain a callback that may already be running (unless we are that callback).
    if DispatchQueue.getSpecific(key: Self.queueKey) == nil { queue.sync {} }
  }

  private func deliver(_ urls: [URL]) {
    let running = lock.withLock { stream != nil }
    if running, !urls.isEmpty { handler(urls) }
  }

  private static let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
    watcher.deliver(paths.map { URL(fileURLWithPath: $0) })
  }
}
