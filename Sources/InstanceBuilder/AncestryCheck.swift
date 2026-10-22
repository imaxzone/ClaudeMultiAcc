import Darwin
import Foundation

/// Executable paths of this process's ancestors (parent first, up to launchd): `sysctl(KERN_PROC_PID)` for the
/// parent pid and `proc_pidpath` for the path. Used to refuse replacing an app that hosts the current session.
public struct AncestryCheck: Sendable {
  private let provider: @Sendable () -> [String]

  public init() {
    self.init(provider: { AncestryCheck.liveChain(from: getpid()) })
  }

  public init(provider: @escaping @Sendable () -> [String]) {
    self.provider = provider
  }

  public func ancestorExecutablePaths() -> [String] {
    provider()
  }

  /// Whether any path lies inside `app` (`<app>/…`).
  public static func anyInside(_ app: URL, _ paths: [String]) -> Bool {
    let prefix = app.standardizedFileURL.path + "/"
    return paths.contains { $0.hasPrefix(prefix) }
  }

  /// The outermost `.app` bundle among `paths` (e.g. `/Applications/Claude.app` for a helper inside it).
  public static func hostApp(in paths: [String]) -> String? {
    for path in paths.reversed() {
      if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
    }
    return nil
  }

  static func liveChain(from start: pid_t) -> [String] {
    var chain: [String] = []
    var pid = parent(of: start)
    var seen: Set<pid_t> = [start]
    while let current = pid, current > 0, !seen.contains(current), chain.count < 64 {
      seen.insert(current)
      if let path = executablePath(current) { chain.append(path) }
      pid = current == 1 ? nil : parent(of: current)
    }
    return chain
  }

  static func parent(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
  }

  static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
    return length > 0 ? String(decoding: buffer.prefix(length), as: UTF8.self) : nil
  }
}
