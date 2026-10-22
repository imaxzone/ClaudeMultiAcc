import Foundation
import Support

extension ClaudeUpdateChecker {
  /// The real machine: Anthropic's feed (`ClaudeFeedFetcher`), the download from downloads.claude.ai, and the installer
  /// that verifies the app and stores it under `<data>/source/`.
  public static func live(paths: Paths, runner: ProcessRunning, appVersion: String) -> ClaudeUpdateChecker {
    let store = ClaudeSourceStore(paths: paths)
    return ClaudeUpdateChecker(
      paths: paths, store: store, feed: ClaudeFeedFetcher(appVersion: appVersion), downloader: ClaudeArchiveDownloader(),
      installer: ClaudeSourceInstaller(paths: paths, store: store, runner: runner))
  }
}
