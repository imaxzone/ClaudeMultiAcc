import Foundation
import os
import Support

/// `FileManager.trashItem`: the Finder's «Переместить в Корзину», restorable until the Trash is emptied.
public struct FinderTrash: Trashing {
  public init() {}

  public func trash(_ url: URL) throws -> URL? {
    var landed: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
    return landed as URL?
  }
}

/// Allocated bytes of the regular files under a path (as `du`), without following symlinks. Runs off the caller's
/// executor and stops early when the waiting task is cancelled.
public struct DiskUsage: SizeMeasuring {
  public init() {}

  public func size(of url: URL) async -> Int64 {
    let work = Task.detached(priority: .utility) { Self.measure(url) }
    return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
  }

  static func measure(_ url: URL) -> Int64 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    switch info.st_mode & S_IFMT {
    case S_IFREG: return Int64(info.st_blocks) * 512
    case S_IFDIR: break
    default: return 0
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                     errorHandler: { _, _ in true })
    else { return 0 }
    var total: Int64 = 0
    var seen = 0
    for case let file as URL in files {
      seen += 1
      if seen % 1000 == 0, Task.isCancelled { return total }
      guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
      total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    return total
  }
}

/// `<data>/update.lock`, shared with the in-app UpdateWatcher, the update LaunchAgent and `rebuild second`.
struct UpdateLockGate: RemovalLocking {
  let paths: Paths

  func tryAcquire() -> RemovalLockAttempt {
    switch UpdateLock.acquire(UpdateLock.file(paths)) {
    case .acquired(let lock): .acquired(release: { lock.release() })
    case .busy: .busy
    case .failed(let code): .failed("errno \(code)")
    }
  }
}

extension InstanceRemover {
  /// The real machine: NSRunningApplication quit requests, NSRunningApplication/lsappinfo/lock running checks, the
  /// Finder Trash, `lsregister -u`, `update.lock` and `~/Library/Logs/ClaudeMultiAcc/instances.log`.
  public static func live(paths: Paths, runner: ProcessRunning) -> InstanceRemover {
    InstanceRemover(
      paths: paths, store: InstanceStore(paths: paths), running: RunningCheck(runner: runner),
      quitter: WorkspaceQuitter(), trasher: FinderTrash(), unregistrar: LaunchServicesUnregistrar(runner: runner),
      sizer: DiskUsage(), lock: UpdateLockGate(paths: paths),
      log: RedactingFileLog(url: paths.logsDir.appendingPathComponent("instances.log")))
  }
}
