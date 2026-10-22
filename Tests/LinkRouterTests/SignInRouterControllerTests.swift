import AppKit
import Foundation
import Support
import Testing
@testable import LinkRouter

/// The four-instance registry in a temp root with fake LaunchServices, delivery and clock. Profiles are real temp
/// directories read by `ProfileSignInReader`; `second` starts signed in, `work` has never been launched.
@MainActor
final class SignInHarness {
  static let secondId = "com.anthropic.claudefordesktop2"
  static let workId = "com.imaxzone.claude.work"

  let root: URL
  let api: FakeSchemeAPI
  let delivery = FakeDelivery()
  let clock = MutableClock()
  var instances: [Instance]
  var running: Set<String> = []
  private(set) var controller: SignInRouterController!

  init(handler: URL? = claudeApp) throws {
    root = try makeTempDir()
    instances = try fourInstances(root: root)
    api = FakeSchemeAPI(handler: handler)
    try signIn("second")
    controller = SignInRouterController(
      ownApp: ownApp, instances: { [unowned self] in self.instances },
      ownership: SchemeOwnership(api: api, ownApp: ownApp), delivery: delivery, clock: clock,
      runningBundleIds: { [unowned self] in self.running })
  }

  var official: URL { root.appendingPathComponent("Applications/Claude.app") }
  func app(_ slug: String) -> URL { root.appendingPathComponent("Applications/\(slug == "work" ? "Claude Work" : "Claude 2nd").app") }
  func profile(_ slug: String) -> URL { root.appendingPathComponent("profiles/\(slug)") }

  func signIn(_ slug: String) throws {
    try writeConfig(#"{"windowSizeWasSignedIn": true, "lastKnownAccountUuid": "u-\#(slug)"}"#, profile: profile(slug))
  }

  func signOut(_ slug: String) throws {
    try writeConfig(#"{"windowSizeWasSignedIn": false, "lastKnownAccountUuid": "u-\#(slug)"}"#, profile: profile(slug))
  }

  /// Routes `link` and waits for the delivery; returns where it went.
  func route(_ link: URL) async -> URL? {
    let before = delivery.calls.count
    controller.handle([link])
    await controller.settle()
    return delivery.calls.count > before ? delivery.calls.last?.app : nil
  }
}

@MainActor
@Suite struct SignInRouterControllerTests {
  @Test func nobodyWaitingForwardsToTheOfficialAppAndNeverTakesTheScheme() async throws {
    let h = try SignInHarness()
    h.controller.start()
    #expect(await h.route(magicLink) == h.official)
    #expect(await h.route(newChatLink) == h.official)
    #expect(h.api.setHandlerCalls.isEmpty)
    #expect(!h.controller.holdsScheme)
    #expect(h.delivery.calls.allSatisfy { $0.activate && $0.app != ownApp })
  }

  @Test func oneWaitingCloneTakesTheSchemeAndGetsTheSignInLink() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    await h.controller.settle()
    #expect(h.controller.holdsScheme)
    #expect(h.controller.waitingSlugs == ["work"])
    #expect(h.api.setHandlerCalls == [ownApp])
    #expect(await h.route(magicLink) == h.app("work"))
    #expect(await h.route(googleLink) == h.app("work"))
    #expect(h.delivery.calls.last == .init(url: googleLink, app: h.app("work"), activate: true))
  }

  @Test func twoWaitingClonesTheMostRecentGetsTheLink() async throws {
    let h = try SignInHarness()
    try h.signOut("second")
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.secondId)
    h.clock.advance(10)
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    #expect(await h.route(magicLink) == h.app("work"))
    h.clock.advance(10)
    h.controller.cloneActivated(bundleId: SignInHarness.secondId)
    #expect(h.controller.waitingSlugs == ["second", "work"])
    #expect(await h.route(magicLink) == h.app("second"))
  }

  @Test func otherLinksWhileWaitingGoToTheOfficialApp() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    #expect(await h.route(newChatLink) == h.official)
    #expect(await h.route(url("claude://claude.ai/code/session_01ABC")) == h.official)
    #expect(h.controller.holdsScheme)
  }

  @Test func signingInEndsTheWaitAndReturnsTheScheme() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    #expect(await h.route(magicLink) == h.app("work"))
    try h.signIn("work")
    h.controller.reevaluate()
    await h.controller.settle()
    #expect(!h.controller.holdsScheme)
    #expect(h.api.setHandlerCalls == [ownApp, h.official])
    #expect(h.api.current == h.official)
    #expect(await h.route(magicLink) == h.official)
  }

  @Test func theWaitEndsAfterThirtyMinutes() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    h.clock.advance(29 * 60)
    h.controller.reevaluate()
    #expect(h.controller.holdsScheme)
    h.clock.advance(60)
    h.controller.reevaluate()
    await h.controller.settle()
    #expect(!h.controller.holdsScheme)
    #expect(h.api.setHandlerCalls == [ownApp, h.official])
  }

  /// A clone that re-registered itself as the handler keeps it: only our own ownership is handed back.
  @Test func aSchemeTakenByAnotherAppIsLeftAlone() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    await h.controller.settle()
    h.api.steal(h.app("work"))
    try h.signIn("work")
    h.controller.reevaluate()
    await h.controller.settle()
    #expect(h.api.setHandlerCalls == [ownApp])
    #expect(h.api.current == h.app("work"))
  }

  @Test func startReturnsALeftoverSchemeWhenNobodyWaits() async throws {
    let h = try SignInHarness(handler: ownApp)
    h.controller.start()
    await h.controller.settle()
    #expect(h.api.setHandlerCalls == [h.official])
  }

  @Test func runningSignedOutClonesAtStartCountAsJustLaunched() async throws {
    let h = try SignInHarness()
    h.running = [SignInHarness.secondId, SignInHarness.workId, "com.anthropic.claudefordesktop"]
    h.controller.start()
    await h.controller.settle()
    #expect(h.controller.waitingSlugs == ["work"])
    #expect(h.api.setHandlerCalls == [ownApp])
  }

  @Test func linksBeforeStartAreRoutedAfterIt() async throws {
    let h = try SignInHarness()
    h.running = [SignInHarness.workId]
    h.controller.handle([magicLink, newChatLink])
    await h.controller.settle()
    #expect(h.delivery.calls.isEmpty)
    h.controller.start()
    await h.controller.settle()
    #expect(h.delivery.apps == [h.app("work"), h.official])
  }

  @Test func aCreatedCloneWaitsBeforeItsFirstLaunch() async throws {
    let h = try SignInHarness()
    h.controller.start()
    let lab = Instance(slug: slug("lab"), name: "Claude Lab", kind: .clone, bundleId: "com.imaxzone.claude.lab",
                       appPath: h.root.appendingPathComponent("Applications/Claude Lab.app").path,
                       profileDir: h.root.appendingPathComponent("profiles/lab").path)
    h.instances.append(lab)
    h.controller.cloneCreated(bundleId: "com.imaxzone.claude.lab")
    await h.controller.settle()
    #expect(h.controller.waitingSlugs == ["lab"])
    #expect(h.api.setHandlerCalls == [ownApp])
  }

  @Test func signedInClonesTheOfficialAppAndStrangersNeverTakeTheScheme() async throws {
    let h = try SignInHarness()
    h.controller.start()
    for id in [SignInHarness.secondId, "com.anthropic.claudefordesktop", "com.apple.Safari"] {
      h.controller.cloneLaunched(bundleId: id)
      h.controller.cloneActivated(bundleId: id)
    }
    await h.controller.settle()
    #expect(!h.controller.holdsScheme)
    #expect(h.api.setHandlerCalls.isEmpty)
  }

  /// Signing out of a clone and bringing it to the front lets it sign in again.
  @Test func aSignedOutCloneWaitsWhenActivated() async throws {
    let h = try SignInHarness()
    h.controller.start()
    try h.signOut("second")
    h.controller.cloneActivated(bundleId: SignInHarness.secondId)
    #expect(await h.route(magicLink) == h.app("second"))
  }

  /// The new-instance flow reports the clone before the registry reload lists it; it waits once it is listed.
  @Test func aCloneCreatedBeforeTheRegistryReloadWaitsOnceListed() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneCreated(bundleId: "com.imaxzone.claude.lab")
    #expect(!h.controller.holdsScheme)
    h.instances.append(Instance(
      slug: slug("lab"), name: "Claude Lab", kind: .clone, bundleId: "com.imaxzone.claude.lab",
      appPath: h.root.appendingPathComponent("Applications/Claude Lab.app").path,
      profileDir: h.root.appendingPathComponent("profiles/lab").path))
    h.controller.instancesChanged()
    await h.controller.settle()
    #expect(h.controller.waitingSlugs == ["lab"])
    #expect(h.api.setHandlerCalls == [ownApp])
  }

  @Test func aQuitCloneStopsWaitingAndTheSchemeGoesBack() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.workspaceNotification(NSWorkspace.didLaunchApplicationNotification, bundleId: SignInHarness.workId)
    #expect(h.controller.holdsScheme)
    h.controller.workspaceNotification(NSWorkspace.didTerminateApplicationNotification, bundleId: SignInHarness.workId)
    await h.controller.settle()
    #expect(!h.controller.holdsScheme)
    #expect(h.api.setHandlerCalls == [ownApp, h.official])
    #expect(await h.route(magicLink) == h.official)
  }

  /// Signing out inside a clone that stays in front sends no activation; leaving it for the browser or Mail to sign
  /// in again does, and from then on it waits.
  @Test func leavingASignedOutCloneMakesItWait() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.workspaceNotification(NSWorkspace.didActivateApplicationNotification, bundleId: SignInHarness.secondId)
    h.clock.advance(45 * 60)
    try h.signOut("second")
    #expect(!h.controller.holdsScheme)
    h.controller.workspaceNotification(NSWorkspace.didDeactivateApplicationNotification, bundleId: SignInHarness.secondId)
    #expect(h.controller.holdsScheme)
    #expect(await h.route(googleLink) == h.app("second"))
  }

  @Test func theLiveControllerFollowsLaunchActivationDeactivationAndQuit() {
    #expect(Set(SignInRouterController.observedNotifications) == [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
    ])
  }

  /// MenuBarApp may report a finished sign-in right away instead of waiting for the next re-check.
  @Test func aReportedSignInReturnsTheSchemeAtOnce() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    try h.signIn("work")
    h.controller.signInStateChanged()
    await h.controller.settle()
    #expect(!h.controller.holdsScheme)
    #expect(h.api.current == h.official)
  }

  @Test func aRemovedCloneStopsWaiting() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    h.instances.removeAll { $0.slug.raw == "work" }
    h.controller.instancesChanged()
    await h.controller.settle()
    #expect(!h.controller.holdsScheme)
    #expect(h.api.setHandlerCalls == [ownApp, h.official])
  }

  @Test func stopHandsTheSchemeBack() async throws {
    let h = try SignInHarness()
    h.controller.start()
    h.controller.cloneLaunched(bundleId: SignInHarness.workId)
    h.controller.stop()
    await h.controller.settle()
    #expect(h.api.current == h.official)
    h.controller.handle([magicLink])
    await h.controller.settle()
    #expect(h.delivery.calls.isEmpty)
  }

  @Test func deliveryFailureDetailIsRedacted() {
    let detail = WorkspaceDelivery.failureDetail(LeakyError())
    #expect(!detail.contains("abc123") && !detail.contains("me@example.com") && !detail.contains("secret"))
    #expect(detail.contains("open failed"))
  }
}

struct LeakyError: Error, CustomStringConvertible {
  var description: String { "open failed for claude://claude.ai/magic-link#secret?code=abc123 of me@example.com" }
}
