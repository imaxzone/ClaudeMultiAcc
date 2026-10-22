import Foundation
import Testing
@testable import Support

@Suite struct ReleaseVersionTests {
  @Test(arguments: [
    ("1.2.3", "1.2.3"), ("v1.2.3", "1.2.3"), ("V2.0", "2.0"), (" 1.4 ", "1.4"), ("7", "7"),
    ("1.2.3.4", "1.2.3.4"), ("v1.5.0-beta.2", "1.5.0-beta.2"), ("1.5.0-rc.1+build.7", "1.5.0-rc.1"),
    ("1.0.0+20261021", "1.0.0"), ("1.0.0-alpha-1", "1.0.0-alpha-1"),
  ])
  func parsesAndNormalizes(text: String, normalized: String) throws {
    let version = try #require(ReleaseVersion(text))
    #expect(version.description == normalized)
  }

  @Test(arguments: [
    "", "v", "vv1.2", "abc", "release-1.2", "1..2", ".1", "1.", "1.2.3.4.5", "1.x", "1.2-", "1.2+", "1.2-beta..1",
    "1.2.3-be ta", "1.2.3-beta_1", "1.2 3", "-1.2", "1.2.3\n", "1234567890.1",
    String(repeating: "1.", count: 40) + "1",
  ])
  func rejectsNonVersions(text: String) {
    #expect(ReleaseVersion(text) == nil)
  }

  @Test func comparesNumericallyNotLexically() throws {
    #expect(try v("1.2.10") > v("1.2.9"))
    #expect(try v("1.10.0") > v("1.9.3"))
    #expect(try v("2.0") > v("1.99.99"))
    #expect(try v("0.1.1") > v("0.1.0"))
    #expect(try v("0.1.0") < v("0.1.1"))
  }

  @Test func missingPartsCountAsZero() throws {
    #expect(try v("1.2") == v("1.2.0"))
    #expect(try v("1") == v("1.0.0.0"))
    #expect(try !(v("1.2") < v("1.2.0")))
    #expect(try v("1.2.0.1") > v("1.2"))
  }

  @Test func leadingVDoesNotMatter() throws {
    #expect(try v("v1.2.3") == v("1.2.3"))
  }

  @Test func buildMetadataIsIgnored() throws {
    #expect(try v("1.0.0+a") == v("1.0.0+b"))
    #expect(try !(v("1.0.0+b") > v("1.0.0")))
  }

  @Test func preReleaseSortsBeforeItsRelease() throws {
    #expect(try v("1.0.0-rc.1") < v("1.0.0"))
    #expect(try v("1.0.0-rc.1") > v("0.9.9"))
    #expect(try v("1.0.1-alpha") > v("1.0.0"))
  }

  /// The precedence example from SemVer 2.0 §11.
  @Test func preReleaseIdentifiersFollowSemVer() throws {
    let ordered = [
      "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
      "1.0.0-rc.1", "1.0.0",
    ]
    let versions = try ordered.map(v)
    for (lower, higher) in zip(versions, versions.dropFirst()) {
      #expect(lower < higher, "\(lower) < \(higher)")
      #expect(!(higher < lower))
    }
  }

  private func v(_ text: String) throws -> ReleaseVersion {
    try #require(ReleaseVersion(text))
  }
}
