import Foundation
import InstanceBuilder
import Support
import Testing
@testable import cmacc

/// `--key value` never swallows the next option as its value (S9).
@Suite struct InstanceOptionsTests {
  @Test func parsesValuesListsFlagsAndPositionals() throws {
    let options = try #require(InstanceOptions.parse(["new", "--name", "Work", "--email", "a@x.io", "--email", "b@y.org",
                                                      "--staging-only"]))
    #expect(options.positional == ["new"])
    #expect(options.values["--name"] == "Work")
    #expect(options.lists["--email"] == ["a@x.io", "b@y.org"])
    #expect(options.flags == ["--staging-only"])
  }

  @Test(arguments: [
    ["--name", "--install"], ["--badge", "--yes"], ["--email", "--staging-only"], ["--slug", "--name", "x"],
    ["--identity", "--keychain", "/k"],
  ])
  func rejectsAnOptionWhereAValueBelongs(args: [String]) {
    #expect(InstanceOptions.parse(args) == nil)
  }

  @Test func rejectsAMissingValueAndUnknownOptions() {
    #expect(InstanceOptions.parse(["--name"]) == nil)
    #expect(InstanceOptions.parse(["--frobnicate"]) == nil)
  }

  @Test func acceptsValuesThatMerelyContainDashes() throws {
    let options = try #require(InstanceOptions.parse(["--name", "my-team", "--badge", "-x"]))
    #expect(options.values["--name"] == "my-team")
    #expect(options.values["--badge"] == "-x")
  }

  /// A staging build signs with the recorded identity from its dedicated keychain (`SigningIdentityProvisioner`).
  @Test func stagingIdentityUsesTheRecordedKeychain() throws {
    let sha1 = String(repeating: "AB", count: 20)
    let recorded = AppSettings.Builder(signingIdentitySHA1: sha1, signingKeychainPath: "/d/signing/cmacc-signing.keychain-db")
    let none = try #require(InstanceOptions.parse([]))
    #expect(try InstanceCommand.stagingIdentity(none, builder: recorded)
      == .certificate(sha1: sha1, keychain: URL(fileURLWithPath: "/d/signing/cmacc-signing.keychain-db")))
    let login = AppSettings.Builder(signingIdentitySHA1: sha1)
    #expect(try InstanceCommand.stagingIdentity(none, builder: login) == .certificate(sha1: sha1, keychain: nil))
    #expect(try InstanceCommand.stagingIdentity(none, builder: AppSettings.Builder()) == .adhoc)
    let override = try #require(InstanceOptions.parse(["--keychain", "/k.keychain-db"]))
    #expect(try InstanceCommand.stagingIdentity(override, builder: recorded)
      == .certificate(sha1: sha1, keychain: URL(fileURLWithPath: "/k.keychain-db")))
    let adhoc = try #require(InstanceOptions.parse(["--identity", "adhoc"]))
    #expect(try InstanceCommand.stagingIdentity(adhoc, builder: recorded) == .adhoc)
  }

  @Test func instanceCommandExitsWithUsageForASwallowedOption() async throws {
    #expect(try await InstanceCommand().run(["new", "--name", "--install", "--yes"]) == ExitCode.usage)
  }
}
