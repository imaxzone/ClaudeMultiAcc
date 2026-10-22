import Foundation
import Support
@testable import LinkRouter

struct FakeSchemeError: Error, Equatable {}

/// In-memory LaunchServices: records every `setHandler` call. Never touches the real `claude://` handler. Every app is
/// the official Claude unless `identities` is given (then only the apps it lists have a bundle id).
final class FakeSchemeAPI: SchemeOwnershipAPI, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: URL?
  private var calls: [URL] = []
  private var callTimes: [Date] = []
  private let failing: Bool
  /// Simulates a Claude app re-registering right after every successful claim.
  private let stolenBy: URL?
  private let clock: MutableClock?
  private let identities: [URL: String]?

  init(handler: URL?, failing: Bool = false, stolenBy: URL? = nil, clock: MutableClock? = nil,
       identities: [URL: String]? = nil) {
    self.handler = handler
    self.failing = failing
    self.stolenBy = stolenBy
    self.clock = clock
    self.identities = identities
  }

  func bundleIdentifier(of app: URL) -> String? {
    guard let identities else { return OfficialApp.bundleId }
    return identities[app]
  }

  var setHandlerCalls: [URL] { lock.withLock { calls } }
  var setHandlerTimes: [Date] { lock.withLock { callTimes } }
  var current: URL? { lock.withLock { handler } }

  func steal(_ app: URL) { lock.withLock { handler = app } }

  func currentHandler(scheme: String) -> URL? { lock.withLock { handler } }

  func setHandler(_ app: URL, scheme: String) async throws {
    try lock.withLock {
      calls.append(app)
      if let clock { callTimes.append(clock.now) }
      if failing { throw FakeSchemeError() }
      handler = app == ownApp ? (stolenBy ?? app) : app
    }
  }
}

/// Records deliveries instead of opening apps.
final class FakeDelivery: URLDelivering, @unchecked Sendable {
  struct Call: Equatable {
    let url: URL
    let app: URL
    let activate: Bool
  }

  private let lock = NSLock()
  private var items: [Call] = []
  private let failingApps: Set<URL>

  init(failing: Set<URL> = []) { failingApps = failing }

  var calls: [Call] { lock.withLock { items } }
  var apps: [URL] { calls.map(\.app) }

  func deliver(_ url: URL, to app: URL, activate: Bool) async throws {
    try lock.withLock {
      items.append(Call(url: url, app: app, activate: activate))
      if failingApps.contains(app) { throw FakeSchemeError() }
    }
  }
}

let ownApp = URL(fileURLWithPath: "/Users/test/Applications/ClaudeMultiAcc.app")
let claudeApp = URL(fileURLWithPath: "/Applications/Claude.app")
