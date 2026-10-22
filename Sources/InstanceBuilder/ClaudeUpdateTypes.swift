import Foundation

/// The full-archive update the Claude feed offers (the `updateTo` of the chosen release; `delta` is never used).
public struct ClaudeRelease: Sendable, Equatable {
  public let version: String
  /// `https://downloads.claude.ai/releases/darwin/…/Claude-<hash>.zip`.
  public let url: URL
  /// 64 lowercase hex digits.
  public let sha256: String
  public let size: Int64

  public init(version: String, url: URL, sha256: String, size: Int64) {
    self.version = version
    self.url = url
    self.sha256 = sha256
    self.size = size
  }
}

/// Where a Claude archive may come from: `https://downloads.claude.ai/releases/darwin/…*.zip`, no port, no user info.
/// The feed's `url` and every redirect of the download must pass.
public enum ClaudeDownloadPolicy {
  public static let host = "downloads.claude.ai"
  static let pathPrefix = "/releases/darwin/"

  public static func isAllowed(_ url: URL?) -> Bool {
    guard let url, url.scheme?.lowercased() == "https", url.host()?.lowercased() == host, url.port == nil,
          url.user() == nil, url.password() == nil
    else { return false }
    let path = url.path(percentEncoded: false)
    return path.hasPrefix(pathPrefix) && path.lowercased().hasSuffix(".zip") && !path.contains("/../")
  }
}

/// What the feed answered for the newest Claude ClaudeMultiAcc already has.
public enum ClaudeFeedAnswer: Sendable, Equatable {
  /// 204/404, or nothing newer than the current version.
  case none
  case available(ClaudeRelease)
}

/// Why a check, download or install of Claude failed; the menu turns each case into a sentence.
public enum ClaudeUpdateFailure: Error, Sendable, Equatable {
  /// `/Applications/Claude.app` is missing or unreadable (downloads need it, see the spec's simplified path).
  case officialMissing
  case network(String)
  /// An HTTP status other than 200/204/404, or a body that is not a usable feed answer.
  case badAnswer(String)
  /// A download URL (or redirect) outside `https://downloads.claude.ai/releases/darwin/`.
  case untrustedURL(String)
  case notEnoughSpace(free: Int64, needed: Int64)
  case sizeMismatch(expected: Int64, actual: Int64)
  case checksumMismatch
  case unpackFailed(String)
  /// Not the vendor app: Team ID, bundle id or `codesign --verify` failed.
  case notGenuine(String)
  case versionMismatch(expected: String, found: String)
  /// An update pass held `update.lock` for too long.
  case busy
  /// The data folder could not be written.
  case storage(String)
}

/// What the Claude update check is doing, for the menu's ↻ button and status line.
public enum ClaudeUpdateStatus: Sendable, Equatable {
  case idle
  case checking
  case downloading(version: String, percent: Int)
  case verifying(version: String)
  /// Nothing newer (only after a manual check; an automatic one goes back to `idle`).
  case upToDate(version: String)
  /// A new version was just stored; the clones are being rebuilt from it.
  case ready(version: String)
  /// Only after a manual check; an automatic one logs and goes back to `idle`.
  case failed(ClaudeUpdateFailure)

  /// The check runs: the button spins and is disabled.
  public var isWorking: Bool {
    switch self {
    case .checking, .downloading, .verifying: true
    default: false
    }
  }

  /// A result the menu shows until it is closed and opened again.
  public var isTransient: Bool {
    switch self {
    case .upToDate, .ready, .failed: true
    default: false
    }
  }
}

/// Asks the Claude feed what is newer than `current`. Throws `ClaudeUpdateFailure`.
public protocol ClaudeFeedFetching: Sendable {
  func latest(current: String, deviceId: String, osVersion: String) async throws -> ClaudeFeedAnswer
}

/// Downloads a release's archive to `file`, reporting progress from 0 to 1 now and then. Throws `ClaudeUpdateFailure`;
/// cancelling the calling task cancels the download.
public protocol ClaudeArchiveDownloading: Sendable {
  func download(_ release: ClaudeRelease, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Verifies a downloaded archive against its release, unpacks and checks the app and moves it into
/// `ClaudeSourceStore`; returns the stored source. Throws `ClaudeUpdateFailure`.
public protocol ClaudeSourceInstalling: Sendable {
  func install(archive: URL, release: ClaudeRelease) async throws -> ClaudeSource
}

/// The menu's ↻: one check (joining a running one); returns the status it ended in.
public protocol ClaudeUpdateChecking: Sendable {
  func checkNow(manual: Bool) async -> ClaudeUpdateStatus
}
