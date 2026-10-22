import CryptoKit
import Foundation
import Support

/// Which source apps the builder accepts, and which vendor team the clone's helpers must still carry.
public struct SourcePolicy: Sendable, Equatable {
  public let expectedBundleId: String
  /// `nil` accepts any team (hermetic test bundles are ad hoc).
  public let expectedTeamId: String?

  public init(expectedBundleId: String, expectedTeamId: String?) {
    self.expectedBundleId = expectedBundleId
    self.expectedTeamId = expectedTeamId
  }

  public static let vendor = SourcePolicy(expectedBundleId: CloneSpec.vendorBundleId, expectedTeamId: Verifier.vendorTeamId)
  public static let relaxedForTests = SourcePolicy(expectedBundleId: CloneSpec.vendorBundleId, expectedTeamId: nil)
}

public struct SourceInfo: Sendable, Equatable, Codable {
  public let url: URL
  public let bundleId: String
  public let version: String
  public let teamId: String
  public let mainExecutableSHA256: String
}

/// Step 2: reads and validates the source app (read-only).
public struct SourceProbe: Sendable {
  private let runner: ProcessRunning
  private let policy: SourcePolicy

  public init(runner: ProcessRunning) {
    self.init(runner: runner, policy: .vendor)
  }

  public init(runner: ProcessRunning, policy: SourcePolicy) {
    self.runner = runner
    self.policy = policy
  }

  public func probe(_ app: URL) async throws -> SourceInfo {
    let infoURL = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: infoURL), let info = try? PlistPatcher.decode(data) else {
      throw BuilderError.sourceUnreadable(app.path)
    }
    let bundleId = info["CFBundleIdentifier"] as? String ?? ""
    guard bundleId == policy.expectedBundleId else { throw BuilderError.unexpectedSourceBundleId(bundleId) }

    let details = try await runner.runChecked(BuilderTool.codesign, ["-dv", "--verbose=2", app.path], timeout: BuilderTool.shortTimeout)
    let team = Verifier.value(of: "TeamIdentifier", in: details.stderrText + details.stdoutText) ?? "not set"
    if let expected = policy.expectedTeamId, team != expected {
      throw BuilderError.unexpectedTeamId(expected: expected, found: team)
    }
    let verify = try await runner.runTool(BuilderTool.codesign, ["--verify", "--strict", app.path], timeout: BuilderTool.signTimeout)
    guard verify.exitCode == 0 else {
      throw BuilderError.sourceSignatureInvalid(verify.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let hash = Self.mainExecutableHash(app) else { throw BuilderError.sourceUnreadable(app.path) }
    return SourceInfo(
      url: app, bundleId: bundleId, version: info["CFBundleShortVersionString"] as? String ?? "unknown",
      teamId: team, mainExecutableSHA256: hash)
  }

  static func mainExecutableHash(_ app: URL) -> String? {
    StaticSmoke.sha256(of: app.appendingPathComponent("Contents/MacOS/Claude"))
  }
}
