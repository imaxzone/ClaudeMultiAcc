import Foundation
import Support
import Testing
@testable import LinkRouter

/// Collects status changes reported by the reclaimer.
final class StatusLog: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [ReclaimStatus] = []
  var all: [ReclaimStatus] { lock.withLock { items } }
  func append(_ status: ReclaimStatus) { lock.withLock { items.append(status) } }
}

@Suite struct ReclaimerTests {
  static let claudeId = "com.anthropic.claudefordesktop"

  private func make(api: FakeSchemeAPI, clock: MutableClock, log: StatusLog = StatusLog()) -> Reclaimer {
    Reclaimer(ownership: SchemeOwnership(api: api, ownApp: ownApp), clock: clock, registryBundleIds: [Self.claudeId]) {
      log.append($0)
    }
  }

  /// Advances the clock one second at a time for `seconds`, running due work each step.
  private func run(_ reclaimer: Reclaimer, clock: MutableClock, seconds: Int, every: ((Int) async -> Void)? = nil) async {
    for second in 0..<seconds {
      await every?(second)
      await reclaimer.runDue()
      clock.advance(1)
    }
  }

  private func offsets(_ api: FakeSchemeAPI) -> [Int] {
    api.setHandlerTimes.map { Int($0.timeIntervalSince(testNow).rounded()) }
  }

  @Test func neverStartedNeverCallsSetHandler() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await run(reclaimer, clock: clock, seconds: 600) { second in
      if second % 7 == 0 { await reclaimer.appLaunched(bundleId: Self.claudeId) }
      if second % 11 == 0 { await reclaimer.prefsChanged() }
    }
    #expect(api.setHandlerCalls.isEmpty)
    #expect(await reclaimer.nextWake() == nil)
  }

  @Test func stoppedNeverClaimsAgain() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await reclaimer.start()
    await reclaimer.stop()
    await run(reclaimer, clock: clock, seconds: 200) { second in
      if second == 10 { await reclaimer.appLaunched(bundleId: Self.claudeId) }
    }
    #expect(api.setHandlerCalls.isEmpty)
    #expect(await reclaimer.isActive == false)
  }

  @Test func claimsAtStartLaunchOffsetsAndPoll() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, stolenBy: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await reclaimer.start()
    await run(reclaimer, clock: clock, seconds: 62) { second in
      if second == 10 { await reclaimer.appLaunched(bundleId: Self.claudeId) }
      if second == 40 { await reclaimer.appLaunched(bundleId: "com.example.unrelated") }
    }
    #expect(offsets(api) == [0, 12, 16, 22, 35, 60])
    #expect(api.setHandlerCalls.allSatisfy { $0 == ownApp })
  }

  @Test func prefsChangeClaimsAfterOneSecond() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: ownApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await reclaimer.start()
    await run(reclaimer, clock: clock, seconds: 5) { second in
      if second == 2 { api.steal(claudeApp); await reclaimer.prefsChanged() }
    }
    #expect(offsets(api) == [3])
  }

  @Test func rateLimitCapsClaimsAtSixPerMinute() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, stolenBy: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await reclaimer.start()
    await run(reclaimer, clock: clock, seconds: 180) { second in
      if second.isMultiple(of: 2) { await reclaimer.prefsChanged() }
    }
    let times = offsets(api)
    #expect(times.count > 6)
    for (index, time) in times.enumerated() {
      #expect(times[index...].prefix { $0 < time + 60 }.count <= 6)
    }
  }

  @Test func failuresBackOffThenStopAfterThree() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, failing: true, clock: clock)
    let log = StatusLog()
    let reclaimer = make(api: api, clock: clock, log: log)
    await reclaimer.start()
    await run(reclaimer, clock: clock, seconds: 900) { second in
      if second == 100 || second == 500 { await reclaimer.appLaunched(bundleId: Self.claudeId) }
    }
    #expect(offsets(api) == [0, 60, 180])
    #expect(await reclaimer.status == .stopped)
    #expect(log.all.last == .stopped)
    #expect(log.all.contains(.failing(1)))
  }

  /// When nobody waits any more the reclaimer forgets a "stopped" verdict; the next wait tries again.
  @Test func stopResetsAStoppedReclaimerToIdle() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, failing: true, clock: clock)
    let log = StatusLog()
    let reclaimer = make(api: api, clock: clock, log: log)
    await reclaimer.start()
    await run(reclaimer, clock: clock, seconds: 900)
    #expect(await reclaimer.status == .stopped)
    await reclaimer.stop()
    #expect(await reclaimer.status == .idle)
    #expect(log.all.last == .idle)
    #expect(await reclaimer.nextWake() == nil)
  }

  @Test func alreadyOwnedHoldsWithoutCallingSetHandler() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: ownApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await reclaimer.start()
    await reclaimer.runDue()
    #expect(await reclaimer.status == .holding)
    #expect(api.setHandlerCalls.isEmpty)
  }
}

/// Ordering of driver operations and overlapping `runDue` calls (S6).
@Suite struct ReclaimerRaceTests {
  private func make(api: FakeSchemeAPI, clock: MutableClock) -> Reclaimer {
    Reclaimer(ownership: SchemeOwnership(api: api, ownApp: ownApp), clock: clock,
              registryBundleIds: [ReclaimerTests.claudeId])
  }

  /// Two loops waking together claim once for the one due item, not twice.
  @Test func overlappingRunsClaimOncePerDueItem() async {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, stolenBy: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    await reclaimer.start()
    async let first: Void = reclaimer.runDue()
    async let second: Void = reclaimer.runDue()
    _ = await (first, second)
    #expect(api.setHandlerCalls.count == 1)
  }

  /// Off then on in quick succession: the final state is "on" with a scheduled wake and a running loop.
  @MainActor
  @Test func fastOffOnLeavesTheLoopRunning() async throws {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, stolenBy: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    let driver = ReclaimerDriver(reclaimer: reclaimer, home: try makeTempDir())
    for _ in 0..<20 {
      driver.setEnabled(true)
      driver.setEnabled(false)
      driver.setEnabled(true)
      await driver.settle()
      #expect(driver.isLooping)
      #expect(await reclaimer.nextWake() != nil)
      driver.setEnabled(false)
      await driver.settle()
      #expect(!driver.isLooping)
      #expect(await reclaimer.nextWake() == nil)
    }
  }

  /// After `quiesce()` nothing the driver started can still claim: the scheme can be handed back safely.
  @MainActor
  @Test func quiesceWaitsForTheLastClaim() async throws {
    let clock = MutableClock()
    let api = FakeSchemeAPI(handler: claudeApp, stolenBy: claudeApp, clock: clock)
    let reclaimer = make(api: api, clock: clock)
    let driver = ReclaimerDriver(reclaimer: reclaimer, home: try makeTempDir())
    driver.setEnabled(true)
    await driver.settle()
    driver.setEnabled(false)
    await driver.quiesce()
    let calls = api.setHandlerCalls.count
    #expect(await reclaimer.isActive == false)
    await reclaimer.runDue()
    #expect(api.setHandlerCalls.count == calls)
  }
}
