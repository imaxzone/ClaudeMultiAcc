import Darwin
import Foundation
import os
import Support

/// Where the running ClaudeMultiAcc.app lies (R2 item 4; R3 offers «Открывать при старте системы» only when installed).
public enum AppLocation: String, Sendable, Equatable {
  /// In `/Applications` or `~/Applications` (subfolders included).
  case applications
  /// App Translocation: macOS runs a quarantined app that Finder did not move from a random read-only mount.
  case translocated
  /// Anywhere else: «Загрузки», a disk image, a development build in `dist/`.
  case elsewhere

  /// The menu offers «Переместить ClaudeMultiAcc в «Программы»?» (`ApplicationsMover.moveAndRelaunch`).
  public var offersMove: Bool { self != .applications }
}

/// App Translocation and install-location checks: a translocated app runs from
/// `/private/var/folders/…/AppTranslocation/<UUID>/d/<name>.app`.
public enum TranslocationCheck {
  /// Pure path rule: under `/private/var/folders` (or `/var/folders`) with an `AppTranslocation/<UUID>/…` part.
  public static func isTranslocated(_ url: URL) -> Bool {
    var parts = url.standardizedFileURL.pathComponents
    if parts.first == "/" { parts.removeFirst() }
    if parts.first == "private" { parts.removeFirst() }
    guard parts.starts(with: ["var", "folders"]), let index = parts.firstIndex(of: "AppTranslocation") else { return false }
    return parts.count > index + 2
  }

  /// Security's `SecTranslocateIsTranslocatedURL` (exported, but without a public header), else the path rule.
  public static func isTranslocatedLive(_ url: URL = Bundle.main.bundleURL) -> Bool {
    if let function = SecTranslocate.isTranslocated() {
      var translocated = false
      if function(url as CFURL, &translocated, nil).boolValue { return translocated }
    }
    return isTranslocated(url)
  }

  /// Where the translocated bundle really lies (`SecTranslocateCreateOriginalPathForURL`); nil when unknown or when
  /// `url` is not translocated.
  public static func originalURL(of url: URL) -> URL? {
    guard isTranslocatedLive(url), let function = SecTranslocate.createOriginal(),
          let original = function(url as CFURL, nil) else { return nil }
    return original.takeRetainedValue() as URL
  }

  /// Pure: the path rule for translocation, then `/Applications/…` or `<home>/Applications/…`.
  public static func location(of bundle: URL, home: URL) -> AppLocation {
    location(of: bundle, home: home, translocated: isTranslocated(bundle))
  }

  /// At startup: `liveLocation()` for the running app (Security's translocation check, then the path rule).
  public static func liveLocation(
    of bundle: URL = Bundle.main.bundleURL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> AppLocation {
    location(of: bundle, home: home, translocated: isTranslocatedLive(bundle))
  }

  static func location(of bundle: URL, home: URL, translocated: Bool) -> AppLocation {
    if translocated { return .translocated }
    let parts = bundle.standardizedFileURL.pathComponents
    let roots = [ApplicationsMover.systemApplications, home.appendingPathComponent("Applications", isDirectory: true)]
    let inside = roots.contains { root in
      let prefix = root.standardizedFileURL.pathComponents
      return parts.count > prefix.count && parts.starts(with: prefix)
    }
    return inside ? .applications : .elsewhere
  }
}

/// Runtime lookup of the two SecTranslocate functions in Security.framework.
private enum SecTranslocate {
  typealias IsTranslocated = @convention(c) (
    CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
  ) -> DarwinBoolean
  typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

  static let framework = "/System/Library/Frameworks/Security.framework/Security"

  static func isTranslocated() -> IsTranslocated? { symbol("SecTranslocateIsTranslocatedURL") }
  static func createOriginal() -> CreateOriginal? { symbol("SecTranslocateCreateOriginalPathForURL") }

  private static func symbol<T>(_ name: String) -> T? {
    guard let handle = dlopen(framework, RTLD_LAZY), let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: T.self)
  }
}

public enum TranslocationError: Error, Equatable {
  case originalUnknown
  /// Something else (another app, a link, a folder without our Info.plist) has the name in «Программы»; its path.
  case foreignAppInTheWay(String)
  /// The copy in «Программы» is newer than the one running.
  case newerCopyInstalled(installed: String, running: String)

  public var userMessage: String {
    switch self {
    case .originalUnknown: BuilderText.string("move.original-unknown")
    case .foreignAppInTheWay(let path): BuilderText.format("move.foreign-app", (path as NSString).lastPathComponent)
    case .newerCopyInstalled(let installed, let running): BuilderText.format("move.newer-installed", installed, running)
    }
  }
}

/// Moves ClaudeMultiAcc.app into «Программы» and relaunches it from there (like LetsMove): copy, remove the
/// quarantine attribute from the copy (otherwise macOS translocates it again, because it was not moved by Finder;
/// the user already approved this app), move the original and any older copy to the Trash.
public struct ApplicationsMover: Sendable {
  public typealias Action = @Sendable (URL) throws -> Void
  public static let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
  private let home: URL
  private let destination: URL?
  private let trash: Action
  private let relaunch: Action
  private let log = AppLog.logger("relocate")

  /// `destination` nil → `destinationDirectory` (live). `relaunch` nil → a detached `/bin/sh` that opens the copy
  /// once this process has exited.
  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    destination: URL? = nil,
    trash: @escaping Action = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
    relaunch: Action? = nil
  ) {
    self.home = home
    self.destination = destination
    self.trash = trash
    self.relaunch = relaunch ?? { try Self.relaunch($0, afterExitOf: getpid()) }
  }

  /// `/Applications` when writable (admin users), else `~/Applications`.
  public static func destinationDirectory(home: URL, isWritable: (String) -> Bool) -> URL {
    isWritable(systemApplications.path) ? systemApplications
      : home.appendingPathComponent("Applications", isDirectory: true)
  }

  /// Copies `bundle` into `directory` and removes quarantine from the copy. Returns the new location. An existing app
  /// of that name goes to the Trash first, but only when it is ClaudeMultiAcc (its bundle id, a real folder) and not
  /// newer than `bundle`; anything else is refused and left alone.
  public func install(_ bundle: URL, into directory: URL) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
    if FileIdentity.of(target) != nil {
      try Self.checkReplaceable(target, by: bundle)
      try trash(target)
    }
    try fm.copyItem(at: bundle, to: target)
    try Quarantine.remove(from: target)
    return target
  }

  /// nil when `running` is already in «Программы». Otherwise installs the real bundle (the translocation original,
  /// or `running` itself), moves the original to the Trash (best effort: a disk image is read-only) and relaunches
  /// the copy. The caller must quit right after (`NSApp.terminate(nil)`): the single-instance guard would end a copy
  /// started while this one still runs.
  public func moveAndRelaunch(running: URL = Bundle.main.bundleURL) throws -> URL? {
    let source: URL
    switch TranslocationCheck.liveLocation(of: running, home: home) {
    case .applications: return nil
    case .translocated:
      guard let original = TranslocationCheck.originalURL(of: running) else { throw TranslocationError.originalUnknown }
      source = original.standardizedFileURL
    case .elsewhere: source = running.standardizedFileURL
    }
    let directory = destination ?? Self.destinationDirectory(home: home) { FileManager.default.isWritableFile(atPath: $0) }
    let target: URL
    if source.deletingLastPathComponent().path == directory.standardizedFileURL.path {
      try Quarantine.remove(from: source)
      target = source
    } else {
      target = try install(source, into: directory)
      do { try trash(source) } catch { log.error("original left in place: \(String(describing: error), privacy: .public)") }
    }
    log.info("relaunching from \(target.path, privacy: .public)")
    try relaunch(target)
    return target
  }

  /// Why `existing` may not be replaced by `bundle`; nothing when it may.
  static func checkReplaceable(_ existing: URL, by bundle: URL) throws {
    let info = FileIdentity.of(existing)?.isDirectory == true ? infoPlist(existing) : nil
    guard let id = info?["CFBundleIdentifier"] as? String, id.lowercased() == BuildInfo.bundleId.lowercased() else {
      throw TranslocationError.foreignAppInTheWay(existing.path)
    }
    if let installed = info?["CFBundleShortVersionString"] as? String,
       let running = infoPlist(bundle)?["CFBundleShortVersionString"] as? String,
       VersionCompare.isNewer(installed, than: running) {
      throw TranslocationError.newerCopyInstalled(installed: installed, running: running)
    }
  }

  private static func infoPlist(_ app: URL) -> [String: Any]? {
    (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))).flatMap { try? PlistPatcher.decode($0) }
  }

  /// The relauncher looks every 0.2 s whether the old process has exited, at most this many times (60 s): a pid that
  /// never exits or was reused by another process must not keep it waiting forever.
  static let relaunchAttempts = 300

  /// `/bin/sh` waits until `pid` has exited (at most `relaunchAttempts` × 0.2 s), then `open`s `app`; paths are
  /// positional parameters, never parsed as code.
  static func relaunch(_ app: URL, afterExitOf pid: pid_t) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = relaunchArguments(app: app, pid: pid)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }

  /// `opener` is `/usr/bin/open` except in tests.
  static func relaunchArguments(
    app: URL, pid: pid_t, attempts: Int = relaunchAttempts, opener: String = "/usr/bin/open"
  ) -> [String] {
    let script = "n=0; while [ \"$n\" -lt \"$3\" ] && /bin/kill -0 \"$1\" 2>/dev/null; do n=$((n + 1)); "
      + "/bin/sleep 0.2; done; exec \"$4\" \"$2\""
    return ["-c", script, "cmacc-relaunch", String(pid), app.path, String(attempts), opener]
  }
}
