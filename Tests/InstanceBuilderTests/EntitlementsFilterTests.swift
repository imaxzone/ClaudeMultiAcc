import Foundation
import Testing
@testable import InstanceBuilder

@Suite struct EntitlementsFilterTests {
  @Test func fixtureFiltersToTenSecurityKeysPlusLibraryValidation() throws {
    let output = try plistDict(try EntitlementsFilter.filter(try fixtureData("entitlements-claude.plist")))
    let expected: Set<String> = [
      "com.apple.security.automation.apple-events", "com.apple.security.cs.allow-jit",
      "com.apple.security.device.audio-input", "com.apple.security.device.bluetooth",
      "com.apple.security.device.camera", "com.apple.security.device.print", "com.apple.security.device.usb",
      "com.apple.security.personal-information.location", "com.apple.security.personal-information.photos-library",
      "com.apple.security.virtualization", "com.apple.security.cs.disable-library-validation",
    ]
    #expect(Set(output.keys) == expected)
    #expect(output.values.allSatisfy { ($0 as? Bool) == true })
  }

  @Test func removesDeveloperAndGroupKeys() throws {
    let input: [String: Any] = [
      "com.apple.developer.icloud-services": ["CloudKit"], "com.apple.security.application-groups": ["g"],
      "com.apple.developer.team-identifier": "T", "keychain-access-groups": ["k"], "com.apple.security.device.usb": true,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: input, format: .xml, options: 0)
    let output = try plistDict(try EntitlementsFilter.filter(data))
    #expect(Set(output.keys) == ["com.apple.security.device.usb", "com.apple.security.cs.disable-library-validation"])
  }

  @Test func forbiddenEntitlementThrows() throws {
    #expect(throws: BuilderError.forbiddenEntitlement("com.apple.security.get-task-allow")) {
      try EntitlementsFilter.filter(try fixtureData("entitlements-forbidden.plist"))
    }
  }

  @Test func forbiddenKeysSetToFalseAreAllowed() throws {
    let input: [String: Any] = ["com.apple.security.cs.allow-dyld-environment-variables": false]
    let data = try PropertyListSerialization.data(fromPropertyList: input, format: .xml, options: 0)
    let output = try plistDict(try EntitlementsFilter.filter(data))
    #expect(output["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool == false)
  }

  @Test func emptyInputYieldsOnlyLibraryValidation() throws {
    let output = try plistDict(try EntitlementsFilter.filter(Data()))
    #expect(Set(output.keys) == ["com.apple.security.cs.disable-library-validation"])
  }

  @Test func garbageThrows() {
    #expect(throws: BuilderError.self) { try EntitlementsFilter.filter(Data("<<not a plist".utf8)) }
  }
}
