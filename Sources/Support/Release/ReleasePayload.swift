import Foundation

/// The fields of GitHub's `GET /repos/{owner}/{repo}/releases/latest` answer that the check uses. `html_url` is not
/// among them: the page the menu opens is built from the validated tag (`ReleasePage`).
struct ReleasePayload: Decodable, Sendable, Equatable {
  /// Larger bodies are refused unread (a real answer is a few KB plus release notes).
  static let maxBytes = 1 << 20

  let tagName: String
  let draft: Bool
  let prerelease: Bool

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case draft, prerelease
  }

  init(tagName: String, draft: Bool, prerelease: Bool) {
    self.tagName = tagName
    self.draft = draft
    self.prerelease = prerelease
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tagName = try container.decode(String.self, forKey: .tagName)
    draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
    prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
  }

  static func decode(_ data: Data) throws -> ReleasePayload {
    guard data.count <= maxBytes else {
      throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Body over \(maxBytes) bytes"))
    }
    return try JSONDecoder().decode(ReleasePayload.self, from: data)
  }

  /// Drafts and pre-releases are never offered: GitHub's flags, or a SemVer pre-release tag such as `v2.0.0-beta.1`
  /// published without the flag.
  var isStable: Bool { !draft && !prerelease && ReleaseVersion(tagName)?.prerelease.isEmpty != false }

  /// The release this payload names, or nil when the tag is not exactly a version.
  var release: ReleaseCheckState.Release? {
    guard let version = ReleaseVersion(tagName), let page = ReleasePage.url(forTag: tagName) else { return nil }
    return ReleaseCheckState.Release(version: version.description, pageURL: page)
  }
}

/// The release page the menu opens in the browser: `https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/<tag>`,
/// built here from a tag that is exactly a version, so no answer from the network can point it anywhere else.
enum ReleasePage {
  static let base = "https://github.com/imaxzone/ClaudeMultiAcc/releases/tag/"

  /// Surrounding spaces are dropped, as `ReleaseVersion` drops them (a git tag never has any).
  static func url(forTag tag: String) -> URL? {
    let trimmed = tag.trimmingCharacters(in: .whitespaces)
    return isValidTag(trimmed) ? URL(string: base + trimmed) : nil
  }

  /// A version (`ReleaseVersion`) spelled only with ASCII letters, digits, `.`, `-` and `+`: no `/`, `%`, `?`, `#`
  /// or spaces, and never a `.`/`..` segment.
  static func isValidTag(_ tag: String) -> Bool {
    !tag.isEmpty && tag.utf8.allSatisfy(isTagByte) && ReleaseVersion(tag) != nil
  }

  /// Exactly a page `url(forTag:)` builds (owner and repo compared case-insensitively, as GitHub treats them).
  /// Also guards pages cached by earlier versions, which took them from `html_url`.
  static func isAllowed(_ url: URL) -> Bool {
    guard url.query == nil, url.fragment == nil, url.user() == nil, url.password() == nil, url.port == nil else {
      return false
    }
    let text = url.absoluteString
    guard text.utf8.count > base.utf8.count, text.prefix(base.count).lowercased() == base.lowercased() else {
      return false
    }
    return isValidTag(String(text.dropFirst(base.count)))
  }

  private static func isTagByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
      UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "+"):
      true
    default: false
    }
  }
}
