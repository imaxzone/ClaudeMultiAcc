import Foundation

/// A release version such as `1.4.2`, `v2.0` or `1.5.0-beta.2+build.7`: one to four numeric parts, an optional
/// pre-release and ignored build metadata. Ordering follows SemVer 2.0: missing parts count as zero
/// (`1.2` == `1.2.0`) and a pre-release sorts before its release (`1.0.0-rc.1` < `1.0.0`).
public struct ReleaseVersion: Sendable, Comparable, CustomStringConvertible {
  static let maxLength = 64
  static let maxParts = 4
  static let maxDigits = 9

  public let numbers: [Int]
  public let prerelease: [String]

  /// Parses `text`, tolerating surrounding spaces and one leading `v`/`V`; nil when it is not a version.
  public init?(_ text: String) {
    var body = Substring(text.trimmingCharacters(in: .whitespaces))
    if body.first == "v" || body.first == "V" { body = body.dropFirst() }
    guard !body.isEmpty, body.count <= Self.maxLength else { return nil }
    let build = body.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
    guard build.count == 1 || Self.identifiers(build[1]) != nil else { return nil }
    let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard let numbers = Self.numbers(parts[0]) else { return nil }
    let prerelease = parts.count > 1 ? Self.identifiers(parts[1]) : []
    guard let prerelease else { return nil }
    self.numbers = numbers
    self.prerelease = prerelease
  }

  /// Normalized form without the `v` and build metadata, e.g. `1.5.0-beta.2`.
  public var description: String {
    let core = numbers.map(String.init).joined(separator: ".")
    return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
  }

  public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { compare(lhs, rhs) == 0 }
  public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool { compare(lhs, rhs) < 0 }

  /// `-1`, `0` or `1` as `a` is lower than, equal to or higher than `b`.
  static func compare(_ a: ReleaseVersion, _ b: ReleaseVersion) -> Int {
    for index in 0..<max(a.numbers.count, b.numbers.count) {
      let left = index < a.numbers.count ? a.numbers[index] : 0
      let right = index < b.numbers.count ? b.numbers[index] : 0
      if left != right { return left < right ? -1 : 1 }
    }
    return comparePrerelease(a.prerelease, b.prerelease)
  }

  private static func comparePrerelease(_ a: [String], _ b: [String]) -> Int {
    if a.isEmpty || b.isEmpty { return a.isEmpty == b.isEmpty ? 0 : (a.isEmpty ? 1 : -1) }
    for (left, right) in zip(a, b) {
      let order = compareIdentifier(left, right)
      if order != 0 { return order }
    }
    return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
  }

  /// Numeric identifiers compare numerically and sort before alphanumeric ones, which compare in ASCII order.
  private static func compareIdentifier(_ left: String, _ right: String) -> Int {
    switch (numeric(left), numeric(right)) {
    case let (l?, r?): l == r ? 0 : (l < r ? -1 : 1)
    case (.some, nil): -1
    case (nil, .some): 1
    case (nil, nil): left == right ? 0 : (left < right ? -1 : 1)
    }
  }

  private static func numbers(_ text: Substring) -> [Int]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...maxParts).contains(parts.count) else { return nil }
    let values = parts.compactMap { part in part.count <= maxDigits ? numeric(part) : nil }
    return values.count == parts.count ? values : nil
  }

  private static func identifiers(_ text: Substring) -> [String]? {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let valid = parts.allSatisfy { part in
      !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    return valid ? parts.map(String.init) : nil
  }

  private static func numeric<S: StringProtocol>(_ text: S) -> Int? {
    guard !text.isEmpty, text.count <= 18, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    return Int(text)
  }
}
