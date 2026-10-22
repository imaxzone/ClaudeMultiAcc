import Foundation

/// Which clones wait for sign-in. A clone waits while its profile is not signed in and it was launched, brought to
/// the front, left or created less than `window` ago (Google's sign-in nonce lives 30 minutes; a magic-link mail
/// arrives well within that). Pure value: the profile reader is the only I/O, time is passed in.
public struct SignInRouter: Sendable {
  public static let defaultWindow: TimeInterval = 30 * 60

  public let window: TimeInterval
  /// Bundle id → the latest launch, activation, deactivation or creation.
  public private(set) var marks: [String: Date] = [:]

  public init(window: TimeInterval = SignInRouter.defaultWindow) {
    self.window = window
  }

  /// Records a launch, activation, deactivation or creation; an older date never replaces a newer one. Marks that
  /// have expired by `date` are dropped, so the table stays small without consulting the registry.
  public mutating func mark(bundleId: String, at date: Date) {
    marks = marks.filter { date.timeIntervalSince($0.value) < window }
    if let current = marks[bundleId], current >= date { return }
    marks[bundleId] = date
  }

  /// The clone quit: it no longer waits.
  public mutating func forget(bundleId: String) {
    marks[bundleId] = nil
  }

  /// Waiting clones, the most recently marked first (ties keep the registry order).
  public func waiting(_ candidates: [SignInCandidate], profiles: SignInStateReading, now: Date) -> [SignInCandidate] {
    let marked = candidates.enumerated().compactMap { index, candidate -> (index: Int, at: Date, candidate: SignInCandidate)? in
      guard let at = marks[candidate.bundleId], now.timeIntervalSince(at) < window else { return nil }
      return (index, at, candidate)
    }
    return marked.filter { !profiles.isSignedIn(profileDir: $0.candidate.profileDir) }
      .sorted { $0.at != $1.at ? $0.at > $1.at : $0.index < $1.index }
      .map(\.candidate)
  }
}

public enum SignInDecision: Sendable, Equatable {
  /// A sign-in link for the waiting clone (the most recent one when several wait).
  case clone(slug: String, app: URL)
  /// Forwarded unchanged to the official Claude.
  case official(app: URL, reason: String)
  case drop(reason: String)

  /// The app that receives the link.
  public var app: URL? {
    switch self {
    case .clone(_, let app), .official(let app, _): app
    case .drop: nil
    }
  }

  /// English, secret-free description for logs and `cmacc route` (never contains link data).
  public var logDescription: String {
    switch self {
    case .clone(let slug, _): "deliver to \(slug) (waiting for sign-in)"
    case .official(_, let reason): "forward to the official Claude (\(reason))"
    case .drop(let reason): "drop (\(reason))"
    }
  }
}

/// Where a link goes. Pure: no I/O, no clock.
public enum SignInPolicy {
  /// Sign-in links go to the first waiting clone; everything else, and sign-in links while nobody waits, go to the
  /// official Claude unchanged. Our own bundle never receives a link (G13).
  public static func decide(_ kind: LinkKind, waiting: [SignInCandidate], official: URL?, ownApp: URL) -> SignInDecision {
    if kind == .notClaude { return .drop(reason: "not a claude:// link") }
    if kind.isSignIn, let clone = waiting.first { return .clone(slug: clone.slug, app: clone.appPath) }
    guard let official, !SchemeOwnership.same(official, ownApp) else { return .drop(reason: "no official Claude app") }
    return .official(app: official, reason: kind.isSignIn ? "no clone waits for sign-in" : "not a sign-in link")
  }
}
