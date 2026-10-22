import Foundation
import Support

/// An exclusive, non-blocking `flock` on `<data>/update.lock`, held for one applying UpdateWatcher pass and for
/// `rebuild second --check|--apply`. The app's watcher, the `update-watcher` LaunchAgent (`cmacc update check
/// --apply-when-idle`) and Step 6 share it, so no two of them build, discard staging or swap at the same time.
struct UpdateLock: Sendable {
  enum Outcome: Sendable {
    case acquired(UpdateLock)
    case busy
    case failed(Int32)
  }

  private let fd: Int32

  /// `<data>/update.lock`.
  static func file(_ paths: Paths) -> URL { paths.dataDir.appendingPathComponent("update.lock") }

  static func acquire(_ url: URL) -> Outcome {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return .failed(errno) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(fd)
      return code == EWOULDBLOCK ? .busy : .failed(code)
    }
    return .acquired(UpdateLock(fd: fd))
  }

  func release() {
    flock(fd, LOCK_UN)
    close(fd)
  }
}

/// Keeps the newest `keep` backups `<appName>.<yyyyMMdd-HHmmss>` of one clone in the backup dir. Backups named
/// `legacy-…` (the pre-step-6 build of a legacy-script clone) are never removed.
enum BackupPruner {
  @discardableResult
  static func prune(backupDir: URL, appName: String, keep: Int) throws -> [URL] {
    let doomed = try doomed(backupDir: backupDir, appName: appName, keep: keep)
    for url in doomed where isRealDirectory(url.path) {
      try FileManager.default.removeItem(at: url)
    }
    return doomed
  }

  /// `prune`, but LaunchServices forgets each backup (`unregister`, which must not throw: log its failure) right before
  /// it is deleted, so no record is left behind for a path that no longer exists.
  @discardableResult
  static func prune(
    backupDir: URL, appName: String, keep: Int, unregister: @Sendable (URL) async -> Void
  ) async throws -> [URL] {
    let doomed = try doomed(backupDir: backupDir, appName: appName, keep: keep)
    for url in doomed where isRealDirectory(url.path) {
      await unregister(url)
      try FileManager.default.removeItem(at: url)
    }
    return doomed
  }

  /// The backups of `appName` beyond the newest `keep`, oldest first (the timestamp sorts lexicographically).
  private static func doomed(backupDir: URL, appName: String, keep: Int) throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: backupDir.path) else { return [] }
    let pattern = "^\(NSRegularExpression.escapedPattern(for: appName))\\.[0-9]{8}-[0-9]{6}$"
    let names = try fm.contentsOfDirectory(atPath: backupDir.path)
      .filter { !$0.hasPrefix(BackupPlan.legacyPrefix) && $0.range(of: pattern, options: .regularExpression) != nil }
      .sorted()
    return names.dropLast(keep).map { backupDir.appendingPathComponent($0, isDirectory: true) }
  }

  /// `lstat`-based: a symlink named like a backup is never followed or removed.
  private static func isRealDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }
}
