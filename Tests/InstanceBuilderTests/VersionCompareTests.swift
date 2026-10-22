import Testing
@testable import InstanceBuilder

@Suite struct VersionCompareTests {
  @Test(arguments: [
    ("1.3.0", "1.2.9", true), ("1.2.10", "1.2.9", true), ("2.0", "1.99.99", true), ("1.2.1", "1.2", true),
    ("1.2", "1.2.0", false), ("1.2.0", "1.2", false), ("1.2.3", "1.2.3", false), ("1.2.3", "1.3", false),
    ("0.9", "1.0", false), ("2.7032.0", "2.7031.9", true), ("10.0", "9.9", true),
    ("1.2.3-beta", "1.2.2", true), ("", "1.0", false), ("1.0", "", true), ("abc", "abc", false),
  ])
  func numericDotComponents(a: String, b: String, newer: Bool) {
    #expect(VersionCompare.isNewer(a, than: b) == newer, "\(a) vs \(b)")
  }
}
