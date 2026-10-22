import Foundation
import Support
import Testing
@testable import LinkRouter

@Suite struct SchemeOwnershipTests {
  @Test func claimsFromAnotherOwner() async {
    let api = FakeSchemeAPI(handler: claudeApp)
    let ownership = SchemeOwnership(api: api, ownApp: ownApp)
    #expect(!ownership.isOwnedByUs())
    #expect(await ownership.claim() == .claimed)
    #expect(api.setHandlerCalls == [ownApp])
    #expect(ownership.isOwnedByUs())
  }

  @Test func alreadyOwnedDoesNothing() async {
    let api = FakeSchemeAPI(handler: ownApp)
    #expect(await SchemeOwnership(api: api, ownApp: ownApp).claim() == .alreadyOwned)
    #expect(api.setHandlerCalls.isEmpty)
  }

  @Test func claimFailureIsReported() async {
    let api = FakeSchemeAPI(handler: nil, failing: true)
    guard case .failed(let message) = await SchemeOwnership(api: api, ownApp: ownApp).claim() else {
      Issue.record("expected failure")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test func handsBackOnlyWhileItIsOurs() async {
    let theirs = FakeSchemeAPI(handler: claudeApp)
    #expect(await SchemeOwnership(api: theirs, ownApp: ownApp).handBack(to: claudeApp) == .notOurs)
    #expect(theirs.setHandlerCalls.isEmpty)
    let nobody = FakeSchemeAPI(handler: nil)
    #expect(await SchemeOwnership(api: nobody, ownApp: ownApp).handBack(to: claudeApp) == .notOurs)
    let ours = FakeSchemeAPI(handler: ownApp)
    #expect(await SchemeOwnership(api: ours, ownApp: ownApp).handBack(to: claudeApp) == .handedBack)
    #expect(ours.setHandlerCalls == [claudeApp])
    #expect(ours.current == claudeApp)
  }

  @Test func neverHandsBackToItself() async {
    let api = FakeSchemeAPI(handler: ownApp)
    #expect(await SchemeOwnership(api: api, ownApp: ownApp).handBack(to: ownApp) == .notOurs)
    #expect(api.setHandlerCalls.isEmpty)
  }

  @Test func handBackFailureIsReported() async {
    let api = FakeSchemeAPI(handler: ownApp, failing: true)
    guard case .failed = await SchemeOwnership(api: api, ownApp: ownApp).handBack(to: claudeApp) else {
      Issue.record("expected failure")
      return
    }
  }

  @Test func ownerReportsBundleIdAndPath() throws {
    let app = try makeTempDir().appendingPathComponent("Fake.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleIdentifier": "com.example.fake", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    let owner = SchemeOwnership(api: FakeSchemeAPI(handler: app), ownApp: ownApp).owner()
    #expect(owner.bundleId == "com.example.fake")
    #expect(owner.path == app)
    let none = SchemeOwnership(api: FakeSchemeAPI(handler: nil), ownApp: ownApp)
    #expect(none.owner().bundleId == nil)
    #expect(none.owner().path == nil)
  }
}

@Suite struct ReclaimScheduleTests {
  let schedule = ReclaimSchedule()
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func launchAndPrefsTimes() {
    #expect(schedule.afterLaunch(at: t0) == [2, 6, 12, 25].map { t0.addingTimeInterval($0) })
    #expect(schedule.afterPrefsChange(at: t0) == t0.addingTimeInterval(1))
    #expect(schedule.pollInterval == 60)
  }

  @Test func rateLimitIsSixPerRollingMinute() {
    let five = (0..<5).map { t0.addingTimeInterval(-Double($0) * 10) }
    #expect(schedule.allow(now: t0, history: five))
    let six = five + [t0.addingTimeInterval(-59)]
    #expect(!schedule.allow(now: t0, history: six))
    let sixWithOld = five + [t0.addingTimeInterval(-60)]
    #expect(schedule.allow(now: t0, history: sixWithOld))
    #expect(schedule.allow(now: t0, history: []))
  }

  @Test func backoffDoublesFromOneMinuteCappedAtThirty() {
    #expect(schedule.backoff(afterFailures: 0) == 0)
    #expect(schedule.backoff(afterFailures: 1) == 60)
    #expect(schedule.backoff(afterFailures: 2) == 120)
    #expect(schedule.backoff(afterFailures: 3) == 240)
    #expect(schedule.backoff(afterFailures: 5) == 960)
    #expect(schedule.backoff(afterFailures: 6) == 1800)
    #expect(schedule.backoff(afterFailures: 40) == 1800)
  }
}

@Suite struct LaunchServicesPrefsTests {
  private func plist(_ handlers: [[String: Any]]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: ["LSHandlers": handlers], format: .binary, options: 0)
  }

  @Test func readsTheClaudeHandlerEntry() throws {
    let data = try plist([
      ["LSHandlerURLScheme": "https", "LSHandlerRoleAll": "com.apple.safari", "LSHandlerModificationDate": 1.0],
      ["LSHandlerURLScheme": "Claude", "LSHandlerRoleAll": "com.anthropic.claudefordesktop2",
       "LSHandlerModificationDate": 780_000_000.5, "LSHandlerPreferredVersions": ["LSHandlerRoleAll": "-"]],
    ])
    let entry = try #require(LaunchServicesPrefs.handler(forScheme: "claude", plist: data))
    #expect(entry.bundleId == "com.anthropic.claudefordesktop2")
    #expect(entry.modificationDate == Date(timeIntervalSinceReferenceDate: 780_000_000.5))
  }

  @Test func missingEntryOrGarbageIsNil() throws {
    #expect(LaunchServicesPrefs.handler(forScheme: "claude", plist: try plist([["LSHandlerURLScheme": "https"]])) == nil)
    #expect(LaunchServicesPrefs.handler(forScheme: "claude", plist: Data("nope".utf8)) == nil)
  }

  @Test func entryWithoutDateStillReportsTheBundle() throws {
    let data = try plist([["LSHandlerURLScheme": "claude", "LSHandlerRoleAll": "com.example.x"]])
    let entry = try #require(LaunchServicesPrefs.handler(forScheme: "claude", plist: data))
    #expect(entry.bundleId == "com.example.x")
    #expect(entry.modificationDate == nil)
  }
}
