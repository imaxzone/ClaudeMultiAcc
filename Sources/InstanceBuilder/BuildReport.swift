import Foundation

public enum BuildIntent: String, Codable, Sendable {
  /// Build and verify in staging only; a running target is recorded, never refused.
  case stagingOnly
  /// Build for installation: a running target is refused up front.
  case install
}

public struct StepRecord: Codable, Sendable, Equatable {
  public let name: String
  public let ok: Bool
  public let ms: Int
  public let detail: String

  public init(name: String, ok: Bool, ms: Int, detail: String) {
    self.name = name
    self.ok = ok
    self.ms = ms
    self.detail = detail
  }
}

public struct BuildFailure: Codable, Sendable, Equatable {
  public let step: String
  public let message: String

  public init(step: String, message: String) {
    self.step = step
    self.message = message
  }
}

/// `<buildDir>/build-report.json`: what was built, how every step went and whether the result verified.
public struct BuildReport: Codable, Sendable {
  public let slug: String
  public let bundleId: String
  public let displayName: String
  public let badge: String?
  public let intent: BuildIntent
  public let sourcePath: String
  public let sourceVersion: String
  public let stagedPath: String
  public let identityKind: String
  public let steps: [StepRecord]
  public let verification: [SmokeCheck]
  public let smoke: [SmokeCheck]
  public let designatedRequirement: String?
  public let requirementFile: String?
  public let failure: BuildFailure?
  public let verified: Bool
  public let startedAt: Date
  public let finishedAt: Date

  public init(
    slug: String, bundleId: String, displayName: String, badge: String?, intent: BuildIntent,
    sourcePath: String, sourceVersion: String, stagedPath: String, identityKind: String, steps: [StepRecord],
    verification: [SmokeCheck], smoke: [SmokeCheck], designatedRequirement: String?, requirementFile: String?,
    failure: BuildFailure?, verified: Bool, startedAt: Date, finishedAt: Date
  ) {
    self.slug = slug
    self.bundleId = bundleId
    self.displayName = displayName
    self.badge = badge
    self.intent = intent
    self.sourcePath = sourcePath
    self.sourceVersion = sourceVersion
    self.stagedPath = stagedPath
    self.identityKind = identityKind
    self.steps = steps
    self.verification = verification
    self.smoke = smoke
    self.designatedRequirement = designatedRequirement
    self.requirementFile = requirementFile
    self.failure = failure
    self.verified = verified
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

/// Anything that builds a clone in staging (the pipeline; fakes in tests).
public protocol CloneBuilding: Sendable {
  func build(spec: CloneSpec, source: URL, identity: SigningIdentity, intent: BuildIntent) async throws -> BuildReport
}

extension InstanceBuildPipeline: CloneBuilding {}
