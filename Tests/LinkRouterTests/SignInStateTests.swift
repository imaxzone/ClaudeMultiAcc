import Foundation
import Support
import Testing
@testable import LinkRouter

/// `config.json` read the way Claude decides "was signed in" (fixtures mirror the real key layout, no real values).
@Suite struct ProfileSignInReaderTests {
  let reader = ProfileSignInReader()

  private func fixture(_ name: String) throws -> URL { try fixtureURL("profiles/\(name)") }

  @Test func freshProfileWithoutConfigIsNotSignedIn() throws {
    let root = try makeTempDir()
    #expect(!reader.isSignedIn(profileDir: root.appendingPathComponent("never-launched")))
    #expect(!reader.isSignedIn(profileDir: root))
  }

  @Test func firstLaunchConfigWithoutAccountIsNotSignedIn() throws {
    #expect(!reader.isSignedIn(profileDir: try fixture("fresh")))
  }

  @Test func signedInFlagWins() throws {
    #expect(reader.isSignedIn(profileDir: try fixture("signed-in")))
    #expect(!reader.isSignedIn(profileDir: try fixture("signed-out")))
  }

  /// Older profiles have only the account uuid; Claude then counts them as signed in, and so do we.
  @Test func accountUuidAloneMeansSignedIn() throws {
    #expect(reader.isSignedIn(profileDir: try fixture("uuid-only")))
  }

  @Test func aFlagOfTheWrongTypeFallsBackToTheUuid() throws {
    let root = try makeTempDir()
    try writeConfig(#"{"windowSizeWasSignedIn": "yes", "lastKnownAccountUuid": "u"}"#, profile: root.appendingPathComponent("a"))
    try writeConfig(#"{"windowSizeWasSignedIn": 1}"#, profile: root.appendingPathComponent("b"))
    #expect(reader.isSignedIn(profileDir: root.appendingPathComponent("a")))
    #expect(!reader.isSignedIn(profileDir: root.appendingPathComponent("b")))
  }

  /// A half-written or broken file never makes ClaudeMultiAcc take the scheme.
  @Test func unreadableConfigCountsAsSignedIn() throws {
    let profile = try makeTempDir()
    try writeConfig("{not json", profile: profile)
    #expect(reader.isSignedIn(profileDir: profile))
  }
}

@Suite struct SignInCandidateTests {
  @Test func onlyClonesWithAppAndProfileAreCandidates() throws {
    let root = try makeTempDir()
    let clones = SignInCandidate.clones(from: try fourInstances(root: root))
    #expect(clones.map(\.slug) == ["second", "work"])
    #expect(clones[1] == SignInCandidate(
      slug: "work", bundleId: "com.imaxzone.claude.work",
      appPath: URL(fileURLWithPath: "\(root.path)/Applications/Claude Work.app"),
      profileDir: URL(fileURLWithPath: "\(root.path)/profiles/work", isDirectory: true)))
  }

  @Test func ourOwnBundleAndIncompleteEntriesAreSkipped() {
    let entries = [
      Instance(slug: slug("me"), name: "me", kind: .clone, bundleId: "com.imaxzone.ClaudeMultiAcc",
               appPath: "/Applications/X.app", profileDir: "/tmp/me"),
      Instance(slug: slug("named"), name: "named", kind: .clone, bundleId: "com.example.named",
               appPath: "/Applications/ClaudeMultiAcc.app", profileDir: "/tmp/named"),
      Instance(slug: slug("noprofile"), name: "p", kind: .clone, bundleId: "com.example.p", appPath: "/Applications/P.app"),
      Instance(slug: slug("noapp"), name: "a", kind: .clone, bundleId: "com.example.a", profileDir: "/tmp/a"),
      Instance(slug: slug("nobundle"), name: "b", kind: .clone, appPath: "/Applications/B.app", profileDir: "/tmp/b"),
    ]
    #expect(SignInCandidate.clones(from: entries).isEmpty)
  }

  @Test func officialAppComesFromTheRegistry() throws {
    let root = try makeTempDir()
    #expect(OfficialApp.from(try fourInstances(root: root)) == URL(fileURLWithPath: "\(root.path)/Applications/Claude.app"))
    #expect(OfficialApp.from([]) == nil)
  }
}

@Suite struct SignInRouterTests {
  let a = candidate("a")
  let b = candidate("b")

  @Test func aCloneWaitsOnlyWhenMarkedRecentlyAndNotSignedIn() {
    var router = SignInRouter()
    #expect(router.waiting([a], profiles: FakeProfiles(), now: testNow).isEmpty)
    router.mark(bundleId: a.bundleId, at: testNow)
    #expect(router.waiting([a], profiles: FakeProfiles(), now: testNow) == [a])
    #expect(router.waiting([a], profiles: FakeProfiles(signedIn: ["a"]), now: testNow).isEmpty)
  }

  @Test func waitingEndsAfterThirtyMinutes() {
    var router = SignInRouter()
    router.mark(bundleId: a.bundleId, at: testNow)
    #expect(router.waiting([a], profiles: FakeProfiles(), now: testNow.addingTimeInterval(30 * 60 - 1)) == [a])
    #expect(router.waiting([a], profiles: FakeProfiles(), now: testNow.addingTimeInterval(30 * 60)).isEmpty)
  }

  @Test func theMostRecentlyMarkedCloneComesFirst() {
    var router = SignInRouter()
    router.mark(bundleId: a.bundleId, at: testNow)
    router.mark(bundleId: b.bundleId, at: testNow.addingTimeInterval(10))
    #expect(router.waiting([a, b], profiles: FakeProfiles(), now: testNow.addingTimeInterval(20)) == [b, a])
    router.mark(bundleId: a.bundleId, at: testNow.addingTimeInterval(15))
    #expect(router.waiting([a, b], profiles: FakeProfiles(), now: testNow.addingTimeInterval(20)) == [a, b])
  }

  @Test func tiesKeepTheRegistryOrder() {
    var router = SignInRouter()
    router.mark(bundleId: b.bundleId, at: testNow)
    router.mark(bundleId: a.bundleId, at: testNow)
    #expect(router.waiting([a, b], profiles: FakeProfiles(), now: testNow) == [a, b])
  }

  @Test func anOlderMarkNeverReplacesANewerOne() {
    var router = SignInRouter()
    router.mark(bundleId: a.bundleId, at: testNow)
    router.mark(bundleId: a.bundleId, at: testNow.addingTimeInterval(-100))
    #expect(router.marks[a.bundleId] == testNow)
  }

  @Test func forgetEndsTheWait() {
    var router = SignInRouter()
    router.mark(bundleId: a.bundleId, at: testNow)
    router.mark(bundleId: b.bundleId, at: testNow)
    router.forget(bundleId: a.bundleId)
    #expect(router.waiting([a, b], profiles: FakeProfiles(), now: testNow) == [b])
  }

  /// Marks of apps that are not (yet) in the registry are kept until they expire, so a clone created before the
  /// registry reloads still waits once it is listed.
  @Test func markingDropsOnlyExpiredMarks() {
    var router = SignInRouter()
    router.mark(bundleId: a.bundleId, at: testNow)
    router.mark(bundleId: "com.example.unlisted", at: testNow.addingTimeInterval(60))
    router.mark(bundleId: b.bundleId, at: testNow.addingTimeInterval(30 * 60))
    #expect(Set(router.marks.keys) == ["com.example.unlisted", b.bundleId])
  }
}

@Suite struct SignInPolicyTests {
  let a = candidate("a")
  let b = candidate("b")

  private func decide(_ link: URL, _ waiting: [SignInCandidate], official: URL? = claudeApp) -> SignInDecision {
    SignInPolicy.decide(LinkClassifier.classify(link), waiting: waiting, official: official, ownApp: ownApp)
  }

  @Test func nobodyWaitingForwardsEvenSignInLinksToTheOfficialApp() {
    #expect(decide(magicLink, []) == .official(app: claudeApp, reason: "no clone waits for sign-in"))
    #expect(decide(newChatLink, []) == .official(app: claudeApp, reason: "not a sign-in link"))
  }

  @Test func everySignInKindGoesToTheWaitingClone() {
    for link in [magicLink, googleLink, url("claude://claude.ai/sso-callback?code=1")] {
      #expect(decide(link, [a]) == .clone(slug: "a", app: a.appPath))
    }
  }

  @Test func severalWaitingTheFirstIsTheMostRecent() {
    #expect(decide(magicLink, [b, a]) == .clone(slug: "b", app: b.appPath))
  }

  @Test func otherLinksWhileWaitingGoToTheOfficialApp() {
    for link in [newChatLink, url("claude://claude.ai/mcp-auth-callback?code=1"), url("claude://claude.ai/code/session_1")] {
      #expect(decide(link, [a]) == .official(app: claudeApp, reason: "not a sign-in link"))
    }
  }

  @Test func neverToItselfOrWithoutAnOfficialApp() {
    #expect(decide(newChatLink, [a], official: nil) == .drop(reason: "no official Claude app"))
    #expect(decide(magicLink, [], official: ownApp) == .drop(reason: "no official Claude app"))
    #expect(decide(url("https://claude.ai/new"), [a]) == .drop(reason: "not a claude:// link"))
  }

  @Test func descriptionsNameOnlyTheSlug() {
    #expect(SignInDecision.clone(slug: "a", app: a.appPath).logDescription == "deliver to a (waiting for sign-in)")
    #expect(SignInDecision.official(app: claudeApp, reason: "x").logDescription == "forward to the official Claude (x)")
    #expect(SignInDecision.drop(reason: "y").logDescription == "drop (y)")
  }
}

@Suite struct SignInReportTests {
  @Test func textShowsKindWaitingAndDecision() {
    let report = SignInReport(url: magicLink, kind: .magicLink, waiting: [candidate("work")],
                              decision: .clone(slug: "work", app: candidate("work").appPath))
    #expect(report.text == """
      url:      claude://claude.ai/magic-link#<redacted>
      kind:     magicLink (sign-in)
      waiting:  work
      decision: deliver to work (waiting for sign-in)
      """)
    #expect(report.decision == "clone" && report.target == "work")
  }

  @Test func neverContainsTheAddressOrToken() throws {
    let report = SignInReport(url: magicLink, kind: .magicLink, waiting: [], decision: .official(app: claudeApp, reason: "r"))
    let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    for output in [report.text, json] {
      #expect(!output.contains("nobody"))
      #expect(!output.contains(base64("nobody@example.com")))
      #expect(!output.contains("0123456789abcdef"))
    }
    #expect(json.contains("\"decision\":\"official\""))
    #expect(report.target == "Claude")
  }

  /// The CLI has no launch history: a running clone whose profile is not signed in counts as waiting.
  @Test func dryRunTreatsRunningSignedOutClonesAsWaiting() throws {
    let root = try makeTempDir()
    let instances = try fourInstances(root: root)
    try writeConfig(#"{"lastKnownAccountUuid": "u"}"#, profile: root.appendingPathComponent("profiles/second"))
    let running: Set<String> = ["com.anthropic.claudefordesktop2", "com.imaxzone.claude.work"]
    let report = SignInReport.dryRun(url: magicLink, instances: instances, runningBundleIds: running, ownApp: ownApp)
    #expect(report.waiting == ["work"])
    #expect(report.summary == "deliver to work (waiting for sign-in)")
    let idle = SignInReport.dryRun(url: magicLink, instances: instances, runningBundleIds: [], ownApp: ownApp)
    #expect(idle.waiting.isEmpty)
    #expect(idle.decision == "official")
    let chat = SignInReport.dryRun(url: newChatLink, instances: instances, runningBundleIds: running, ownApp: ownApp)
    #expect(chat.summary == "forward to the official Claude (not a sign-in link)")
  }
}
