import Foundation
import InstanceBuilder
import os
import Support

/// Makes the Dock redraw the icon of the given clone(s) (the ones just edited): a pinned clone shows its old icon until
/// then. Runs only when «Обновить Док» on the done screen is clicked, never on its own.
public typealias InstanceEditorRefreshDock = @Sendable ([URL]) async throws -> Void

/// Where «Обновить Док» is.
public enum DockRefreshState: Equatable, Sendable {
  case idle, refreshing, refreshed, failed
}

public enum InstanceEditorDockError: Error, Equatable, Sendable {
  /// `killall Dock` exited with this code (1: no Dock process), or timed out (nil).
  case failed(exitCode: Int32?)
}

/// The live `refreshDock`. `killall Dock` alone often brings back the old icon: the Dock reloads its own per-user
/// icon cache, and LaunchServices keeps an app whose dates did not change. So, in this order:
/// 1. the bundle and its `Contents/Info.plist` get a new modification date;
/// 2. `lsregister -f <app>` re-registers it;
/// 3. the Dock's icon cache file `<DARWIN_USER_CACHE_DIR>/com.apple.dock.iconcache` (user-owned, rebuilt by the Dock)
///    is removed — that one file, only when it is a regular file (never through a symlink);
/// 4. `/usr/bin/killall Dock`: macOS starts the Dock again at once; windows and apps stay open.
/// A failure of steps 1–3 is only logged; only step 4 decides the outcome.
public enum InstanceEditorDock {
  static let killall = URL(fileURLWithPath: "/usr/bin/killall")
  static let timeout: Duration = .seconds(10)
  static let iconCacheName = "com.apple.dock.iconcache"

  /// `staging` refuses staged bundles (never touched or registered, G12); `cacheDirectory` is the per-user cache dir
  /// (default: `confstr(_CS_DARWIN_USER_CACHE_DIR)`). Every command goes through `runner`.
  public static func restart(
    runner: ProcessRunning = SystemProcessRunner(), staging: StagingArea? = nil,
    cacheDirectory: @escaping @Sendable () -> URL? = InstanceEditorDock.darwinUserCacheDirectory
  ) -> InstanceEditorRefreshDock {
    { apps in
      let log = AppLog.logger("instance-editor")
      let registrar = Registrar(runner: runner, staging: staging)
      for app in apps {
        if let staging, staging.contains(app) {
          log.error("Dock refresh: \(app.path, privacy: .public) is a staged bundle, skipped")
          continue
        }
        touch(app, log: log)
        await register(app, with: registrar, log: log)
      }
      removeIconCache(in: cacheDirectory(), log: log)
      try await killDock(runner: runner, log: log)
    }
  }

  /// The per-user cache dir (`getconf DARWIN_USER_CACHE_DIR`); nil when the system gives none.
  public static func darwinUserCacheDirectory() -> URL? {
    let size = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, size) == size else { return nil }
    let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  /// Step 1: like `touch app app/Contents/Info.plist`; each failure is logged.
  static func touch(_ app: URL, log: Logger) {
    let now = Date()
    for url in [app, app.appendingPathComponent("Contents/Info.plist")] {
      do {
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        log.info("Dock refresh: touched \(url.path, privacy: .public)")
      } catch {
        let reason = String(describing: error)
        log.error("Dock refresh: cannot touch \(url.path, privacy: .public): \(reason, privacy: .public)")
      }
    }
  }

  /// Step 2: `lsregister -f app`; a failure is logged.
  static func register(_ app: URL, with registrar: Registrar, log: Logger) async {
    do {
      try await registrar.register(app)
    } catch {
      let reason = String(describing: error)
      log.error("Dock refresh: lsregister -f \(app.path, privacy: .public) failed: \(reason, privacy: .public)")
    }
  }

  /// Step 3: removes `<cacheDir>/com.apple.dock.iconcache` when lstat finds a regular file there; nothing else, ever.
  static func removeIconCache(in cacheDir: URL?, log: Logger) {
    guard let cacheDir else {
      log.error("Dock refresh: no per-user cache dir, the Dock icon cache stays")
      return
    }
    let file = cacheDir.appendingPathComponent(iconCacheName, isDirectory: false)
    var info = stat()
    guard lstat(file.path, &info) == 0 else {
      let code = errno
      let reason = code == ENOENT ? "not there" : String(cString: strerror(code))
      log.info("Dock refresh: no Dock icon cache at \(file.path, privacy: .public) (\(reason, privacy: .public))")
      return
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      log.error("Dock refresh: \(file.path, privacy: .public) is not a regular file, left alone")
      return
    }
    do {
      try FileManager.default.removeItem(at: file)
      log.info("Dock refresh: removed \(file.path, privacy: .public)")
    } catch {
      let reason = String(describing: error)
      log.error("Dock refresh: cannot remove \(file.path, privacy: .public): \(reason, privacy: .public)")
    }
  }

  /// Step 4: `/usr/bin/killall Dock`; a non-zero exit or a timeout is the error the button shows.
  static func killDock(runner: ProcessRunning, log: Logger) async throws {
    let result = try await runner.run(ProcessRequest(executable: killall, arguments: ["Dock"], timeout: timeout))
    guard !result.timedOut, result.exitCode == 0 else {
      throw InstanceEditorDockError.failed(exitCode: result.timedOut ? nil : result.exitCode)
    }
    log.info("restarted the Dock")
  }
}

/// «Обновить Док» on the done screen of «Изменить…» (a save or a reinstall; a new app has no old icon in the Dock).
extension InstanceEditorViewModel {
  public var offersDockRefresh: Bool {
    guard mode != .add, case .done = phase else { return false }
    return true
  }

  /// Once refreshed the button stays disabled; after a failure it retries.
  public var canRefreshDock: Bool { offersDockRefresh && (dockRefresh == .idle || dockRefresh == .failed) }

  public var dockButtonTitle: String {
    dockRefresh == .refreshed ? InstanceEditorText.dockRefreshed : InstanceEditorText.refreshDock
  }

  /// The edited clone as saved (its app after a rename): the bundle the Dock redraws.
  var dockApps: [URL] {
    original?.appPath.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
  }

  /// The line next to the button: what the Dock restart does, or that it failed.
  public var dockNote: String {
    dockRefresh == .failed ? InstanceEditorText.dockRefreshFailed : InstanceEditorText.dockRefreshNote
  }

  public func refreshDock() async {
    guard canRefreshDock else { return }
    dockRefresh = .refreshing
    do {
      try await restartDock(dockApps)
      dockRefresh = .refreshed
    } catch {
      log.error("Dock restart failed: \(String(describing: error), privacy: .public)")
      dockRefresh = .failed
    }
  }
}
