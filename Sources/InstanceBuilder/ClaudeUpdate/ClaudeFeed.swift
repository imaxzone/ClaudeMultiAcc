import Foundation

/// Anthropic's update feed for Claude Desktop, the one Claude's own Squirrel updater asks:
/// `GET <endpoint>?device_id=<uuid>&version=<current>&os_version=<macOS>`. 204/404 mean nothing newer; 200 carries a
/// JSON list of releases, each with a full zip (`updateTo`) and a `delta` that is never used. This type only builds
/// the request and reads the answer; `ClaudeFeedFetcher` sends it.
public enum ClaudeFeed {
  public static let endpoint = "https://api.anthropic.com/api/desktop/darwin/arm64/squirrel/update"
  /// The only host an offered zip may come from (`ClaudeDownloadPolicy` checks the whole URL).
  static let downloadHost = ClaudeDownloadPolicy.host
  /// Larger offers are refused: the real zip is about 264 MB, and the checker needs this much free space anyway.
  static let maxArchiveSize: Int64 = 2_000_000_000
  /// Larger answers are refused unread (a real one is under 1 KB).
  static let maxBodyBytes = 1 << 20
  static let timeout: TimeInterval = 30
  static let maxHeaderLength = 200
  /// How much of an untrusted URL a failure repeats (for the log).
  static let maxExcerpt = 200

  /// The feed request: exactly `device_id`, `version` and `os_version`, an `Accept: application/json` (as Squirrel
  /// sends) and `User-Agent: ClaudeMultiAcc/<appVersion>` (`unknown` when the value is not plain printable ASCII).
  /// `deviceId` must be a UUID (sent in its lowercase form), `current` a store version (`ClaudeSourceStore`) and
  /// `osVersion` one to three numbers (`26.0.1`); anything else is refused before it can leave the Mac
  /// (`ClaudeUpdateFailure.network`, as the question could not be asked).
  static func request(current: String, deviceId: String, osVersion: String, appVersion: String) throws -> URLRequest {
    guard let device = UUID(uuidString: deviceId) else { throw refused("device id") }
    guard ClaudeSourceStore.isValidVersion(current) else { throw refused("version") }
    guard isOSVersion(osVersion) else { throw refused("os version") }
    guard var components = URLComponents(string: endpoint) else { throw refused("endpoint") }
    components.queryItems = [
      URLQueryItem(name: "device_id", value: device.uuidString.lowercased()),
      URLQueryItem(name: "version", value: current),
      URLQueryItem(name: "os_version", value: osVersion),
    ]
    guard let url = components.url else { throw refused("endpoint") }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let version = isSafeHeaderValue(appVersion) ? appVersion : "unknown"
    request.setValue("ClaudeMultiAcc/\(version)", forHTTPHeaderField: "User-Agent")
    return request
  }

  /// What an HTTP answer offers for `current`: 204/404 → `.none`; 200 → the chosen release's full zip, or `.none`
  /// when it is not strictly newer than `current`; any other status → `.badAnswer("HTTP <n>")`.
  /// The chosen release is the entry named by `currentRelease`, else the highest version. Throws
  /// `ClaudeUpdateFailure.badAnswer` for an unreadable body, a version that is not a store version, a checksum that is
  /// not 64 hex digits or a size outside 1…`maxArchiveSize`, and `.untrustedURL` for a zip URL that
  /// `ClaudeDownloadPolicy` refuses. A release that is not newer is `.none` whatever else it says: nothing is
  /// downloaded for it.
  static func answer(status: Int, body: Data, current: String) throws -> ClaudeFeedAnswer {
    switch status {
    case 204, 404:
      return .none
    case 200:
      guard let offer = try Payload.decode(body).chosen?.updateTo else { return .none }
      return try release(offer, current: current)
    default:
      throw ClaudeUpdateFailure.badAnswer("HTTP \(status)")
    }
  }

  private static func release(_ offer: Payload.Update, current: String) throws -> ClaudeFeedAnswer {
    guard ClaudeSourceStore.isValidVersion(offer.version) else {
      throw ClaudeUpdateFailure.badAnswer("invalid version \(excerpt(offer.version))")
    }
    guard VersionCompare.isNewer(offer.version, than: current) else { return .none }
    guard let url = URL(string: offer.url, encodingInvalidCharacters: false), ClaudeDownloadPolicy.isAllowed(url) else {
      throw ClaudeUpdateFailure.untrustedURL(excerpt(offer.url))
    }
    let sha256 = offer.sha256.lowercased()
    guard isHexDigest(sha256) else { throw ClaudeUpdateFailure.badAnswer("invalid sha256") }
    guard (1...maxArchiveSize).contains(offer.size) else {
      throw ClaudeUpdateFailure.badAnswer("invalid size \(offer.size)")
    }
    return .available(ClaudeRelease(version: offer.version, url: url, sha256: sha256, size: offer.size))
  }

  static func isSafeHeaderValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= maxHeaderLength && value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
  }

  /// One to three dot-separated numbers of up to four digits (`26`, `26.0`, `26.0.1`).
  static func isOSVersion(_ value: String) -> Bool {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return false }
    return parts.allSatisfy { part in (1...4).contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } }
  }

  /// 64 lowercase hex digits.
  static func isHexDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  /// At most `maxExcerpt` characters of `text`, anything but printable ASCII shown as `?` (it ends up in the log).
  static func excerpt(_ text: String) -> String {
    let scalars = text.unicodeScalars.prefix(maxExcerpt).map { (0x20...0x7E).contains($0.value) ? $0 : "?" }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func refused(_ field: String) -> ClaudeUpdateFailure {
    .network("invalid request: \(field)")
  }

  /// The fields of the feed's JSON the check uses; everything else (`name`, `notes`, `pub_date`, `delta`) is ignored.
  struct Payload: Decodable {
    struct Release: Decodable {
      let version: String
      let updateTo: Update
    }

    struct Update: Decodable {
      let version: String
      let url: String
      let sha256: String
      let size: Int64
    }

    let currentRelease: String?
    let releases: [Release]

    /// The entry `currentRelease` names, else the highest version; nil for an empty list.
    var chosen: Release? {
      releases.first { $0.version == currentRelease }
        ?? releases.max { VersionCompare.isNewer($1.version, than: $0.version) }
    }

    static func decode(_ body: Data) throws -> Payload {
      guard body.count <= ClaudeFeed.maxBodyBytes else {
        throw ClaudeUpdateFailure.badAnswer("answer over \(ClaudeFeed.maxBodyBytes) bytes")
      }
      do {
        return try JSONDecoder().decode(Payload.self, from: body)
      } catch {
        throw ClaudeUpdateFailure.badAnswer("unreadable answer")
      }
    }
  }
}
