import Darwin
import Foundation

/// Main executable of every clone (D6): pins the clone's profile, keeps one instance per profile, then
/// `execv`s the real Electron binary `Contents/MacOS/Claude.real`.
@main
struct CloneLauncherMain {
  static func main() {
    let config: LauncherConfig
    do {
      config = try LauncherConfig.load(from: .main)
    } catch {
      fail("cannot load launcher config: \(error)", code: 78)
    }
    switch ProfileLock.acquire(profileDir: config.profileDir) {
    case .failure(.busy):
      Activation.activateOther(bundleId: config.bundleId, ownPid: getpid())
      exit(0)
    case .failure(let error):
      fail("cannot lock profile \(config.profileDir): \(error)", code: 73)
    case .success:
      break
    }
    let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    LaunchLog.append(
      LaunchLog.line(date: Date(), pid: getpid(), version: bundleVersion, profileDir: config.profileDir),
      to: config.logFile)
    let plan = LaunchPlanner.plan(config: config, bundlePath: Bundle.main.bundlePath, argv: CommandLine.arguments)
    exec(plan)
  }

  private static func exec(_ plan: LaunchPlan) -> Never {
    var cArgs: [UnsafeMutablePointer<CChar>?] = plan.arguments.map { strdup($0) }
    cArgs.append(nil)
    execv(plan.executable, cArgs)
    fail("execv \(plan.executable) failed: errno \(errno)", code: 71)
  }

  private static func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("CloneLauncher: \(message)\n".utf8))
    exit(code)
  }
}
