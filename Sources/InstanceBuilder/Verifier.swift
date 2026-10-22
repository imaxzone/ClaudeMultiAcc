import Foundation
import Support

public struct VerifyResult: Codable, Sendable, Equatable {
  public let passed: Bool
  public let checks: [SmokeCheck]

  public init(checks: [SmokeCheck]) {
    self.checks = checks
    self.passed = checks.allSatisfy(\.passed)
  }
}

/// Signature checks of a staged clone with `codesign` (read-only).
public struct Verifier: Sendable {
  public static let vendorTeamId = "Q6L2SF6YDW"
  private let runner: ProcessRunning
  private let helperTeamId: String?

  /// `helperTeamId: nil` skips the vendor-helper check (hermetic test bundles are ad hoc throughout).
  public init(runner: ProcessRunning, helperTeamId: String? = Verifier.vendorTeamId) {
    self.runner = runner
    self.helperTeamId = helperTeamId
  }

  /// `expectedEntitlements`: the filtered set `Claude.real` must carry; `nil` checks the filter invariants instead.
  /// `allowCustomIcon` (only `cmacc instance verify` of an installed clone): when `Icon\r` is present, report it as an
  /// informational `custom-icon` pass, verify with `--deep` but without `--strict` (the icon is unsealed by design,
  /// see `CustomIconCheck`) and require separately that nothing else unsealed sits in the bundle root.
  public func verify(
    app: URL, spec: CloneSpec, expectedEntitlements: Data? = nil, allowCustomIcon: Bool = false
  ) async throws -> VerifyResult {
    let real = app.appendingPathComponent("Contents/MacOS/Claude.real")
    var checks = try await signatureChecks(app: app, allowCustomIcon: allowCustomIcon)
    checks += try await identityChecks(prefix: "app", target: app, spec: spec)
    checks += try await identityChecks(prefix: "real", target: real, spec: spec)
    checks.append(try await entitlementsCheck(real: real, expected: expectedEntitlements))
    checks.append(try await helperCheck(app: app))
    return VerifyResult(checks: checks)
  }

  private func signatureChecks(app: URL, allowCustomIcon: Bool) async throws -> [SmokeCheck] {
    let inspection = CustomIconCheck.inspect(app)
    guard allowCustomIcon, inspection.present else {
      let deep = try await runner.runTool(
        BuilderTool.codesign, ["--verify", "--deep", "--strict", "--verbose=2", app.path], timeout: BuilderTool.signTimeout)
      return [SmokeCheck("codesign-verify-deep-strict", deep.exitCode == 0, lastLine(deep.stderrText))]
    }
    let deep = try await runner.runTool(
      BuilderTool.codesign, ["--verify", "--deep", "--verbose=2", app.path], timeout: BuilderTool.signTimeout)
    let (icon, root) = CustomIconCheck.checks(inspection)
    return [icon, SmokeCheck("codesign-verify-deep", deep.exitCode == 0, lastLine(deep.stderrText)), root]
  }

  private func identityChecks(prefix: String, target: URL, spec: CloneSpec) async throws -> [SmokeCheck] {
    let result = try await runner.runTool(BuilderTool.codesign, ["-dv", "--verbose=4", target.path], timeout: BuilderTool.shortTimeout)
    let text = result.stderrText + result.stdoutText
    let identifier = Self.value(of: "Identifier", in: text) ?? "missing"
    let flags = text.split(separator: "\n").lazy.map { Self.flags(in: String($0)) }.first { !$0.isEmpty } ?? []
    return [
      SmokeCheck("\(prefix)-identifier", identifier == spec.bundleId, identifier),
      SmokeCheck("\(prefix)-runtime", flags.contains("runtime"), flags.joined(separator: ",")),
    ]
  }

  private func entitlementsCheck(real: URL, expected: Data?) async throws -> SmokeCheck {
    let result = try await runner.runTool(
      BuilderTool.codesign, ["-d", "--entitlements", "-", "--xml", real.path], timeout: BuilderTool.shortTimeout)
    guard let actual = try? EntitlementsFilter.decode(result.stdout) else {
      return SmokeCheck("real-entitlements", false, "unreadable entitlements")
    }
    if let expected {
      let wanted = (try? EntitlementsFilter.decode(expected)) ?? [:]
      let equal = NSDictionary(dictionary: actual).isEqual(to: wanted)
      return SmokeCheck("real-entitlements", equal, equal ? "\(actual.count) keys match" : "differs from filtered set")
    }
    let refiltered = (try? EntitlementsFilter.filter(result.stdout)).flatMap { try? EntitlementsFilter.decode($0) }
    let stable = refiltered.map { NSDictionary(dictionary: actual).isEqual(to: $0) } ?? false
    return SmokeCheck("real-entitlements", stable, stable ? "\(actual.count) keys satisfy the filter" : "not a filtered set")
  }

  private func helperCheck(app: URL) async throws -> SmokeCheck {
    guard let helperTeamId else { return SmokeCheck("helper-team-id", true, "skipped: no vendor team expected") }
    let helper = app.appendingPathComponent("Contents/Frameworks/Claude Helper.app")
    let result = try await runner.runTool(BuilderTool.codesign, ["-dv", "--verbose=2", helper.path], timeout: BuilderTool.shortTimeout)
    let team = Self.value(of: "TeamIdentifier", in: result.stderrText + result.stdoutText) ?? "missing"
    return SmokeCheck("helper-team-id", team == helperTeamId, team)
  }

  /// `Key=value` lookup in `codesign -dv` output.
  static func value(of key: String, in text: String) -> String? {
    text.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
  }

  /// The names inside `flags=0x…(a,b)`.
  static func flags(in line: String) -> [String] {
    guard let range = line.range(of: #"flags=0x[0-9a-fA-F]+\(([^)]*)\)"#, options: .regularExpression) else { return [] }
    let match = line[range]
    guard let open = match.firstIndex(of: "("), let close = match.lastIndex(of: ")") else { return [] }
    return match[match.index(after: open)..<close].split(separator: ",").map(String.init)
  }

  private func lastLine(_ text: String) -> String {
    text.split(separator: "\n").last.map(String.init) ?? ""
  }
}
