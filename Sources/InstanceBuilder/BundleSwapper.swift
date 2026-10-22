import Foundation
import os
import Support

public enum SwapError: Error, Equatable, Sendable {
  case liveMissing(String)
  case stagedMissing(String)
  case backupExists(String)
  case differentVolumes(String, String)
  /// The installed app is not the one checked before the swap (another device or inode); nothing was moved.
  case liveChanged(String)
  /// A step failed and undoing it failed too; `leftAt` is where the previously installed bundle is now.
  case compensationFailed(original: String, leftAt: String)
}

extension SwapError: CustomStringConvertible {
  /// English, for the CLI and logs.
  public var description: String {
    switch self {
    case .liveMissing(let path): "installed app not found at \(path)"
    case .stagedMissing(let path): "staged build not found at \(path)"
    case .backupExists(let path): "backup target already exists: \(path)"
    case .differentVolumes(let a, let b): "\(a) and \(b) are on different volumes"
    case .liveChanged(let path): "installed app at \(path) changed since it was checked; nothing swapped"
    case .compensationFailed(let original, let leftAt):
      "swap failed (\(original)) and could not be undone — the previous app is at \(leftAt); move it back by hand"
    }
  }
}

/// Replaces an installed app with a staged build by renames only (same volume), keeping the old bundle as a
/// backup whose `Info.plist` is renamed to `Info.plist.disabled` so nothing launches it by bundle id. LaunchServices still
/// keeps a record of the moved bundle (and its helpers), so callers `unregister` the backup after registering the new app
/// (`AppRegistering.unregisterLogged`; `LaunchServicesCleanup.sweep` catches anything left).
public enum BundleSwapper {
  static let disabledPlist = FileMover.disabledPlist

  /// `mv live → <backupDir>/<prefix><name>.<yyyyMMdd-HHmmss>`, disable its Info.plist, `mv staged → live`.
  /// On any failure every completed step is undone and the error rethrown. Returns the backup path.
  /// `backupPrefix` "legacy-" marks the backup of a legacy-script clone, which `BackupPruner` never removes.
  /// `expectedLive` (what `ClonePathPolicy` checked) is compared with `live` right before the first rename.
  public static func swap(
    live: URL, staged: URL, backupDir: URL, now: Date, timeZone: TimeZone = .current, backupPrefix: String = "",
    mover: FileMover = .live, expectedLive: FileIdentity? = nil
  ) throws -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: live.path) else { throw SwapError.liveMissing(live.path) }
    guard fm.fileExists(atPath: staged.path) else { throw SwapError.stagedMissing(staged.path) }
    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
    try requireSameVolume(staged, live.deletingLastPathComponent())
    try requireSameVolume(backupDir, live.deletingLastPathComponent())
    let backup = BackupPlan(backupDir: backupDir, appName: live.lastPathComponent, now: now, timeZone: timeZone,
                            prefix: backupPrefix).target
    guard !fm.fileExists(atPath: backup.path) else { throw SwapError.backupExists(backup.path) }
    if let expectedLive, FileIdentity.of(live) != expectedLive { throw SwapError.liveChanged(live.path) }

    try mover.move(live, backup)
    do {
      try mover.disablePlist(in: backup)
    } catch {
      if let undo = attemptUndo("restore live", log: logError, { try mover.move(backup, live) }) {
        throw SwapError.compensationFailed(original: "\(error); undo: \(undo)", leftAt: backup.path)
      }
      throw error
    }
    do {
      try mover.move(staged, live)
    } catch {
      let enable = attemptUndo("enable backup plist", log: logError) { try mover.enablePlist(in: backup) }
      let restore = attemptUndo("restore live", log: logError) { try mover.move(backup, live) }
      if enable != nil || restore != nil {
        throw SwapError.compensationFailed(original: String(describing: error), leftAt: restore == nil ? live.path : backup.path)
      }
      throw error
    }
    return backup
  }

  private static func logError(_ message: String) {
    AppLog.logger("bundle-swapper").error("\(message, privacy: .public)")
  }

  /// Renames only work within one volume; refuses (instead of a slow, non-atomic copy) otherwise.
  static func requireSameVolume(_ a: URL, _ b: URL) throws {
    guard Volume.same(a, b) else { throw SwapError.differentVolumes(a.path, b.path) }
  }
}

/// Volume identity of the deepest existing ancestor of a path (`URLResourceKey.volumeIdentifierKey`).
public enum Volume {
  public static func identifier(_ url: URL) -> String? {
    var existing = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      existing = existing.deletingLastPathComponent()
    }
    let values = try? existing.resourceValues(forKeys: [.volumeIdentifierKey])
    return values?.volumeIdentifier.map { String(describing: $0) }
  }

  public static func same(_ a: URL, _ b: URL) -> Bool {
    guard let left = identifier(a), let right = identifier(b) else { return false }
    return left == right
  }
}
