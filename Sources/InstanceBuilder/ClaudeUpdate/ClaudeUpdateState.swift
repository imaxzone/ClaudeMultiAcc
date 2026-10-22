import Foundation
import Support

extension Paths {
  /// The Claude update check's own state (`<data>/claude-update.json`): the random `device_id` sent to the feed.
  public var claudeUpdateFile: URL { dataDir.appendingPathComponent("claude-update.json") }
}

/// What `<data>/claude-update.json` holds: the random id the Claude feed receives as `device_id` (ClaudeMultiAcc creates
/// it once; it is never taken from Claude, so nothing in the request identifies the owner's Claude installation), and
/// the last archive that failed verification, which the automatic checks do not download again.
struct ClaudeUpdateState: Codable, Sendable, Equatable {
  let deviceId: String
  var rejectedVersion: String?
  var rejectedSHA256: String?

  init(deviceId: String, rejectedVersion: String? = nil, rejectedSHA256: String? = nil) {
    self.deviceId = deviceId
    self.rejectedVersion = rejectedVersion
    self.rejectedSHA256 = rejectedSHA256
  }

  /// The stored state when it holds a valid id.
  static func load(_ file: URL) -> ClaudeUpdateState? {
    guard let data = try? Data(contentsOf: file), let state = try? JSONCoding.decoder.decode(Self.self, from: data),
          UUID(uuidString: state.deviceId) != nil
    else { return nil }
    return state
  }

  /// `release`'s archive (version and checksum) failed verification before.
  static func isRejected(_ release: ClaudeRelease, in file: URL) -> Bool {
    guard let state = load(file) else { return false }
    return state.rejectedVersion == release.version && state.rejectedSHA256 == release.sha256
  }

  /// Remembers `release`'s archive as rejected, keeping the device id. Throws when the file cannot be written.
  static func reject(_ release: ClaudeRelease, in file: URL) throws {
    var state = load(file) ?? ClaudeUpdateState(deviceId: UUID().uuidString.lowercased())
    state.rejectedVersion = release.version
    state.rejectedSHA256 = release.sha256
    try AtomicFile.write(JSONCoding.encoder.encode(state), to: file, permissions: 0o600)
  }

  /// The stored id, or a fresh random one written (0600) in place of a missing, unreadable or invalid file.
  /// Throws `ClaudeUpdateFailure.storage` when the fresh one cannot be written.
  static func deviceId(in file: URL) throws -> String {
    if let state = load(file) { return state.deviceId }
    let fresh = ClaudeUpdateState(deviceId: UUID().uuidString.lowercased())
    do {
      try AtomicFile.write(JSONCoding.encoder.encode(fresh), to: file, permissions: 0o600)
    } catch {
      throw ClaudeUpdateFailure.storage("cannot write \(file.lastPathComponent): \(error)")
    }
    return fresh.deviceId
  }
}

/// How one check pass ended; `line` is what `updates.log` records.
enum ClaudeUpdateOutcome: Sendable, Equatable {
  /// The feed offered nothing newer than this version (the newest source).
  case upToDate(String)
  /// `source` was downloaded, verified and stored; `from` was the newest source before.
  case stored(from: String, ClaudeSource)
  case failed(ClaudeUpdateFailure)
  /// An automatic check met the archive that failed verification before; only ↻ downloads it again.
  case skippedRejected(String)
  /// `stop()` cut the pass short.
  case cancelled

  var line: String {
    switch self {
    case .upToDate(let version): "none newer than \(version)"
    case .stored(let from, let source): "\(from) → stored \(source.version)"
    case .failed(let failure): "failed: \(failure)"
    case .skippedRejected(let version): "\(version) skipped: its archive failed verification before (↻ retries)"
    case .cancelled: "cancelled"
    }
  }

  /// The status the pass ends in: results and failures only for a manual check, `ready` for both kinds.
  func status(manual: Bool) -> ClaudeUpdateStatus {
    switch self {
    case .upToDate(let version): manual ? .upToDate(version: version) : .idle
    case .stored(_, let source): .ready(version: source.version)
    case .failed(let failure): manual ? .failed(failure) : .idle
    case .skippedRejected, .cancelled: .idle
    }
  }
}
