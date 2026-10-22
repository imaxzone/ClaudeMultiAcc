import Darwin
import Foundation
import Support

/// What Squirrel's ShipIt is doing with the source app.
/// - `idle`: no ShipIt job.
/// - `waitingForQuit`: ShipIt runs but the source app is still running; ShipIt only replaces the bundle after the
///   app terminated, so nothing touches it and a build may proceed.
/// - `installing`: ShipIt runs and the source app is gone; the bundle may be replaced at any moment.
public enum VendorUpdateState: Sendable, Equatable {
  case idle, waitingForQuit, installing
}

public protocol VendorUpdateChecking: Sendable {
  func state() async -> VendorUpdateState
}

/// Classifies ShipIt of the source app: active when a process runs from its `Squirrel.framework` or its launchd job
/// is `state = running`; then `installing` unless the source app itself still runs (G9 via `RunningCheck`).
public struct VendorUpdateCheck: VendorUpdateChecking {
  static let serviceLabel = "com.anthropic.claudefordesktop.ShipIt"
  static let fallbackBundleId = "com.anthropic.claudefordesktop"
  private let runner: ProcessRunning
  private let sourceApp: URL
  private let uid: uid_t
  private let processPaths: @Sendable () -> [String]
  private let isSourceRunning: @Sendable () async -> Bool

  public init(
    runner: ProcessRunning, sourceApp: URL, uid: uid_t = getuid(),
    processPaths: @escaping @Sendable () -> [String] = VendorUpdateCheck.allProcessPaths,
    isSourceRunning: (@Sendable () async -> Bool)? = nil
  ) {
    self.runner = runner
    self.sourceApp = sourceApp
    self.uid = uid
    self.processPaths = processPaths
    self.isSourceRunning = isSourceRunning ?? { [runner, sourceApp] in
      await VendorUpdateCheck.isRunning(sourceApp, check: RunningCheck(runner: runner))
    }
  }

  /// The source app itself runs (G9, by bundle id and exact bundle path). Unknown → false, i.e. `installing`.
  public static func isRunning(_ sourceApp: URL, check: RunningCheck) async -> Bool {
    await check.isRunning(bundleId: bundleId(of: sourceApp), at: sourceApp)
  }

  public func state() async -> VendorUpdateState {
    guard await isShipItRunning() else { return .idle }
    return await isSourceRunning() ? .waitingForQuit : .installing
  }

  private func isShipItRunning() async -> Bool {
    let squirrel = sourceApp.appendingPathComponent("Contents/Frameworks/Squirrel.framework").path + "/"
    if processPaths().contains(where: { $0.hasPrefix(squirrel) }) { return true }
    let result = try? await runner.runTool(
      BuilderTool.launchctl, ["print", "gui/\(uid)/\(Self.serviceLabel)"], timeout: BuilderTool.shortTimeout)
    guard let result, result.exitCode == 0 else { return false }
    return result.stdoutText.split(separator: "\n").contains {
      $0.trimmingCharacters(in: .whitespaces) == "state = running"
    }
  }

  /// `CFBundleIdentifier` of `<app>/Contents/Info.plist`, or the vendor id when it is unreadable.
  static func bundleId(of app: URL) -> String {
    let info = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: info),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty
    else { return fallbackBundleId }
    return id
  }

  /// Executable paths of every visible process (`proc_listallpids` + `proc_pidpath`).
  public static func allProcessPaths() -> [String] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    guard capacity > 64 else { return [] }
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return pids.prefix(max(0, count)).compactMap { pid in
      guard pid > 0 else { return nil }
      let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
      return length > 0 ? String(decoding: buffer.prefix(length), as: UTF8.self) : nil
    }
  }
}
