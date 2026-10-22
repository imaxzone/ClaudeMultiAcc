import Foundation
import Support

/// What `cmacc route --dry-run` prints: the link kind, who waits for sign-in and the decision, with the URL
/// redacted — never an address, token or code.
public struct SignInReport: Sendable, Encodable, Equatable {
  public let url: String
  public let kind: String
  public let signIn: Bool
  public let waiting: [String]
  /// clone | official | drop
  public let decision: String
  public let summary: String
  /// The slug of the clone, or the app name of the official Claude.
  public let target: String?

  public init(url: URL, kind: LinkKind, waiting: [SignInCandidate], decision: SignInDecision) {
    self.url = Redactor.redact(url)
    self.kind = kind.rawValue
    signIn = kind.isSignIn
    self.waiting = waiting.map(\.slug)
    summary = decision.logDescription
    switch decision {
    case .clone(let slug, _):
      self.decision = "clone"
      target = slug
    case .official(let app, _):
      self.decision = "official"
      target = app.deletingPathExtension().lastPathComponent
    case .drop:
      self.decision = "drop"
      target = nil
    }
  }

  /// The decision for `url` from the registry alone. The CLI has no launch history, so a clone counts as waiting
  /// when it runs and its profile is not signed in.
  public static func dryRun(
    url: URL, instances: [Instance], runningBundleIds: Set<String>, ownApp: URL,
    profiles: SignInStateReading = ProfileSignInReader(), officialFallback: URL? = nil, now: Date = Date()
  ) -> SignInReport {
    let candidates = SignInCandidate.clones(from: instances)
    var router = SignInRouter()
    for candidate in candidates where runningBundleIds.contains(candidate.bundleId) {
      router.mark(bundleId: candidate.bundleId, at: now)
    }
    let waiting = router.waiting(candidates, profiles: profiles, now: now)
    let kind = LinkClassifier.classify(url)
    let official = OfficialApp.from(instances) ?? officialFallback
    let decision = SignInPolicy.decide(kind, waiting: waiting, official: official, ownApp: ownApp)
    return SignInReport(url: url, kind: kind, waiting: waiting, decision: decision)
  }

  public var text: String {
    [
      "url:      \(url)",
      "kind:     \(kind)\(signIn ? " (sign-in)" : "")",
      "waiting:  \(waiting.isEmpty ? "-" : waiting.joined(separator: ", "))",
      "decision: \(summary)",
    ].joined(separator: "\n")
  }
}
