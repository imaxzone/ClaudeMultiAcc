import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

struct FakeRunningCheck: RunningChecking {
  let running: Bool
  func isRunning(bundleId: String, profileDir: URL?) async -> Bool { running }
}

struct FakeVendorUpdateCheck: VendorUpdateChecking {
  let fixed: VendorUpdateState
  init(state: VendorUpdateState) { fixed = state }
  func state() async -> VendorUpdateState { fixed }
}

/// Answers `states` in order (the last one repeats) and reports each call number to `onCall` first.
final class SequencedVendorCheck: VendorUpdateChecking {
  private let calls = Mutex(0)
  private let states: [VendorUpdateState]
  private let onCall: @Sendable (Int) -> Void

  init(_ states: [VendorUpdateState], onCall: @escaping @Sendable (Int) -> Void = { _ in }) {
    self.states = states
    self.onCall = onCall
  }

  var callCount: Int { calls.withLock { $0 } }

  func state() async -> VendorUpdateState {
    let call = calls.withLock { count in
      count += 1
      return count
    }
    onCall(call)
    return states[min(call, states.count) - 1]
  }
}

struct FixedClock: Support.Clock {
  let now: Date
}

/// Simulates cp, xattr, codesign and iconutil well enough for the pipeline to run end to end without tools.
enum PipelineFakeRunner {
  struct Options: Sendable {
    var verifyExit: Int32 = 0
    var mutateSourceOnCopy = false
    /// Rewrites the source's `CFBundleShortVersionString` after the copy (main executable untouched).
    var bumpSourceVersionOnCopy = false
  }

  static func make(spec: CloneSpec, options: Options = Options()) throws -> ScriptedRunner {
    let vendorXML = String(decoding: try fixtureData("entitlements-claude.plist"), as: UTF8.self)
    let filteredXML = String(decoding: try EntitlementsFilter.filter(Data(vendorXML.utf8)), as: UTF8.self)
    let icons = fakeIconutil()
    return ScriptedRunner { request in
      let args = request.arguments
      switch request.executable.lastPathComponent {
      case "cp":
        let result = try copy(args, mutateSource: options.mutateSourceOnCopy)
        if options.bumpSourceVersionOnCopy { try bumpVersion(of: URL(fileURLWithPath: args[1])) }
        return result
      case "xattr": return .ok()
      case "iconutil": return try icons.responder(request)
      case "codesign":
        return codesign(args, spec: spec, vendorXML: vendorXML, filteredXML: filteredXML, verifyExit: options.verifyExit)
      default: return .fail(127, stderr: "unexpected tool \(request.executable.path)")
      }
    }
  }

  private static func copy(_ args: [String], mutateSource: Bool) throws -> ProcessResult {
    guard args.count == 3, args[0] == "-Rc" else { return .fail(64, stderr: "bad cp args \(args)") }
    try FileManager.default.copyItem(atPath: args[1], toPath: args[2])
    if mutateSource { try Data("updated-electron".utf8).write(to: URL(fileURLWithPath: args[1] + "/Contents/MacOS/Claude")) }
    return .ok()
  }

  private static func bumpVersion(of app: URL) throws {
    let url = app.appendingPathComponent("Contents/Info.plist")
    var info = try plistDict(try Data(contentsOf: url))
    info["CFBundleShortVersionString"] = "9.9.9"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url)
  }

  private static func codesign(
    _ args: [String], spec: CloneSpec, vendorXML: String, filteredXML: String, verifyExit: Int32
  ) -> ProcessResult {
    let target = args.last ?? ""
    if args.contains("--force") { return .ok() }
    if args.first == "--verify" {
      if args.contains("--deep") { return verifyExit == 0 ? .ok(stderr: "valid on disk\n") : .fail(verifyExit, stderr: "invalid") }
      return .ok()
    }
    if args.contains("--entitlements") { return .ok(stdout: target.hasSuffix("Claude.real") ? filteredXML : vendorXML) }
    if args.contains("-r-") { return .ok(stdout: "designated => identifier \"\(spec.bundleId)\" and cdhash H\"00\"\n") }
    if args.contains("--verbose=4") {
      return .ok(stderr: "Identifier=\(spec.bundleId)\nCodeDirectory v=20500 size=1 flags=0x10002(adhoc,runtime) hashes=1\n")
    }
    return .ok(stderr: "Identifier=x\nTeamIdentifier=Q6L2SF6YDW\n")
  }
}
