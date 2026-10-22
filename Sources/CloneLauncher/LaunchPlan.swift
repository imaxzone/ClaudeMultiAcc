import Foundation

struct LaunchPlan: Equatable {
  let executable: String
  let arguments: [String]
}

enum LaunchPlanner {
  /// `argv[0]` becomes the real Electron binary, the profile flag comes first, and caller-supplied
  /// `--user-data-dir=…` and Finder `-psn_…` arguments are dropped.
  static func plan(config: LauncherConfig, bundlePath: String, argv: [String]) -> LaunchPlan {
    let executable = "\(bundlePath)/Contents/MacOS/\(config.realExecutable)"
    let passthrough = argv.dropFirst().filter { !$0.hasPrefix("--user-data-dir=") && !$0.hasPrefix("-psn_") }
    return LaunchPlan(executable: executable, arguments: [executable, "--user-data-dir=\(config.profileDir)"] + passthrough)
  }
}

enum LaunchLog {
  static func line(date: Date, pid: Int32, version: String, profileDir: String) -> String {
    "\(date.formatted(.iso8601)) pid=\(pid) version=\(version) profile=\(profileDir)\n"
  }

  /// Appends `line` to `path` (0600), creating parent directories; failures are reported on stderr only.
  static func append(_ line: String, to path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      FileHandle.standardError.write(Data("CloneLauncher: cannot open log \(path)\n".utf8))
      return
    }
    defer { close(fd) }
    _ = fchmod(fd, 0o600)
    let bytes = Array(line.utf8)
    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
  }
}
