import Foundation

/// One named pass/fail check with a short human-readable detail.
public struct SmokeCheck: Codable, Sendable, Equatable {
  public let name: String
  public let passed: Bool
  public let detail: String

  public init(name: String, passed: Bool, detail: String) {
    self.name = name
    self.passed = passed
    self.detail = detail
  }

  init(_ name: String, _ passed: Bool, _ detail: String) {
    self.init(name: name, passed: passed, detail: detail)
  }

  static func skipped(_ name: String, _ reason: String) -> SmokeCheck {
    SmokeCheck(name: name, passed: true, detail: "skipped: \(reason)")
  }
}
