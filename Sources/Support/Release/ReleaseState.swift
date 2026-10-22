import Foundation
import os

/// What the release check remembers between launches (`<data>/release-check.json`).
public struct ReleaseCheckState: Codable, Sendable, Equatable {
  /// A stable release as last seen on GitHub, whether or not it is newer than the running app.
  public struct Release: Codable, Sendable, Equatable {
    /// Normalized version without the leading `v`, e.g. `1.2.0`.
    public let version: String
    public let pageURL: URL

    public init(version: String, pageURL: URL) {
      self.version = version
      self.pageURL = pageURL
    }
  }

  /// When the last request went out (successful or not); drives the once-a-day throttle.
  public let lastCheck: Date?
  /// `ETag` of the response that produced `latest`, sent back as `If-None-Match`.
  public let etag: String?
  public let latest: Release?

  public static let empty = ReleaseCheckState(lastCheck: nil, etag: nil, latest: nil)

  public init(lastCheck: Date?, etag: String?, latest: Release?) {
    self.lastCheck = lastCheck
    self.etag = etag
    self.latest = latest
  }

  /// A copy stamped with the time of a request.
  public func with(lastCheck: Date) -> ReleaseCheckState {
    ReleaseCheckState(lastCheck: lastCheck, etag: etag, latest: latest)
  }

  /// A copy holding a new answer from GitHub.
  public func with(etag: String?, latest: Release?) -> ReleaseCheckState {
    ReleaseCheckState(lastCheck: lastCheck, etag: etag, latest: latest)
  }
}

extension Paths {
  /// Release-check cache: last request time, `ETag` and the last stable release seen.
  public var releaseCheckFile: URL { dataDir.appendingPathComponent("release-check.json") }
}

/// Reads and atomically writes the release-check state. It is only a cache: a missing or unreadable file reads as
/// `.empty`, and a write failure is logged, never thrown.
struct ReleaseStateStore: Sendable {
  let file: URL
  private let log = AppLog.logger("release-check")

  init(file: URL) {
    self.file = file
  }

  func load() -> ReleaseCheckState {
    guard FileManager.default.fileExists(atPath: file.path) else { return .empty }
    do {
      return try JSONCoding.decoder.decode(ReleaseCheckState.self, from: Data(contentsOf: file))
    } catch {
      log.error("Unreadable release-check state, starting fresh: \(String(describing: error), privacy: .public)")
      return .empty
    }
  }

  func save(_ state: ReleaseCheckState) {
    do {
      try AtomicFile.write(JSONCoding.encoder.encode(state), to: file, permissions: 0o600)
    } catch {
      log.error("Cannot write release-check state: \(String(describing: error), privacy: .public)")
    }
  }
}
