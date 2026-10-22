import AppKit

enum Activation {
  /// Brings the already running clone (same bundle id, another pid) to the front. Returns whether one was found.
  @discardableResult
  static func activateOther(bundleId: String, ownPid: Int32) -> Bool {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
      .filter { $0.processIdentifier != ownPid }
    guard let other = others.first else { return false }
    return other.activate()
  }
}
