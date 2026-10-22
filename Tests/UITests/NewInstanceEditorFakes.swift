import AppKit
import Foundation
import InstanceBuilder
import Support
import Synchronization
@testable import UI

/// Records every call of the editor window; answers from canned values.
final class EditorFakeServices: InstanceEditorServices {
  struct Knobs: Sendable {
    var identity: SigningIdentity? = .certificate(sha1: String(repeating: "AB", count: 20), keychain: nil)
    var verified = true
    var buildError: (any Error & Sendable)?
    var installError: (any Error & Sendable)?
    var editError: (any Error & Sendable)?
    var running = false
    var existingApps: Set<String> = []
    var leftover = false
    var openFails = false
    var applicationsDir = URL(fileURLWithPath: "/nonexistent-apps", isDirectory: true)
  }

  let existing: [Instance]
  let knobs: Knobs
  private let calls = Mutex<[String]>([])

  init(existing: [Instance], _ knobs: Knobs = Knobs()) {
    self.existing = existing
    self.knobs = knobs
  }

  var recorded: [String] { calls.withLock { $0 } }
  private func record(_ call: String) { calls.withLock { $0.append(call) } }

  func existingInstances() async throws -> [Instance] { existing }

  func validate(_ request: NewInstanceRequest, existing: [Instance]) -> [NewInstanceError] {
    request.validate(against: existing, applicationsDir: knobs.applicationsDir, home: URL(fileURLWithPath: "/Users/u"))
  }

  func permanentIdentity() async -> SigningIdentity? { knobs.identity }

  func build(_ request: NewInstanceRequest, identity: SigningIdentity) async throws -> BuildReport {
    record("build(\(request.slug),\(request.displayName),\(request.badge ?? "-"))")
    if let error = knobs.buildError { throw error }
    return BuildReport(
      slug: request.slug, bundleId: "com.imaxzone.claude.\(request.slug)", displayName: request.displayName,
      badge: request.badge, intent: .stagingOnly, sourcePath: "/Applications/Claude.app", sourceVersion: "2.0.0",
      stagedPath: "/tmp/staging/\(request.slug).noindex/\(request.displayName).app", identityKind: identity.kind,
      steps: [StepRecord(name: "copy", ok: true, ms: 10, detail: "ok")], verification: [],
      smoke: [SmokeCheck(name: "info-id", passed: true, detail: "ok")], designatedRequirement: nil, requirementFile: nil,
      failure: knobs.verified ? nil : BuildFailure(step: "verify", message: "bad signature"), verified: knobs.verified,
      startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 1))
  }

  func discard(slug: String) async throws { record("discard(\(slug))") }

  func install(staged: URL, request: NewInstanceRequest, report: BuildReport) async throws -> Instance {
    record("install(\(request.slug))")
    if let error = knobs.installError { throw error }
    return Instance(slug: try Slug(request.slug), name: request.displayName, kind: .clone,
                    appPath: knobs.applicationsDir.appendingPathComponent("\(request.displayName).app").path, builtBy: "cmacc")
  }

  func newRequest(name: String, badge: String, existing: [Instance]) -> NewInstanceRequest {
    NewInstanceRequest.app(named: name, badge: badge, existing: existing, home: URL(fileURLWithPath: "/Users/u"))
  }

  func isRunning(_ instance: Instance) async -> Bool { knobs.running }

  func appExists(_ app: URL) -> Bool { knobs.existingApps.contains(app.path) }

  func leftoverProfile(slug: String, existing: [Instance]) -> URL? {
    knobs.leftover ? URL(fileURLWithPath: "/Users/u/Library/Application Support/ClaudeProfiles/\(slug)") : nil
  }

  func trashLeftoverProfile(slug: String, existing: [Instance]) async throws { record("trashLeftover(\(slug))") }

  func open(app: URL) async throws {
    record("open(\(app.lastPathComponent))")
    if knobs.openFails { throw CocoaError(.fileNoSuchFile) }
  }

  func edit(
    _ change: InstanceChange, identity: SigningIdentity, progress: @escaping @Sendable (EditStage) async -> Void
  ) async throws -> EditOutcome {
    let flag = change.reinstall ? ",reinstall" : ""
    record("edit(\(change.slug.raw),\(change.name),\(change.badge),\(identity.kind)\(flag))")
    await progress(.building)
    if knobs.running { await progress(.closing) }
    if let error = knobs.editError { throw error }
    await progress(.installing)
    if knobs.running { await progress(.reopening) }
    guard let old = existing.first(where: { $0.slug == change.slug }) else { throw EditInstanceError.notFound(change.slug.raw) }
    let edited = Instance(slug: old.slug, name: change.name, kind: old.kind, bundleId: old.bundleId,
                          appPath: old.appPath, profileDir: old.profileDir, badge: change.badge, builtBy: "cmacc")
    return EditOutcome(instance: edited, renamed: change.name != old.name, wasRunning: knobs.running,
                       reopened: knobs.running, warnings: [])
  }
}

@MainActor
final class EditorFakeDialogs: InstanceEditorDialogs {
  var confirmAnswer: Bool
  private(set) var confirmations = 0

  init(confirm: Bool = true) {
    confirmAnswer = confirm
  }

  func confirmInstall(request: NewInstanceRequest, report: BuildReport) async -> Bool {
    confirmations += 1
    return confirmAnswer
  }
}

/// The `ensureSigning` of a test: counts calls, returns `identity` or throws when it is nil.
final class SigningProbe: Sendable {
  static let certificate = SigningIdentity.certificate(sha1: String(repeating: "CD", count: 20), keychain: nil)
  private let calls = Mutex(0)
  let identity: SigningIdentity?

  init(_ identity: SigningIdentity? = SigningProbe.certificate) {
    self.identity = identity
  }

  convenience init(fails: Bool) {
    self.init(fails ? nil : Self.certificate)
  }

  var count: Int { calls.withLock { $0 } }

  var closure: InstanceEditorEnsureSigning {
    { [self] in
      calls.withLock { $0 += 1 }
      guard let identity else { throw InstanceEditorSigningError.unavailable }
      return identity
    }
  }
}
