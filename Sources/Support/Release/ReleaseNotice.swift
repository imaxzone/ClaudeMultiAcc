import Foundation

/// The menu's «new ClaudeMultiAcc version» notice. After `start()` it offers the cached answer at once, checks
/// GitHub about a minute after launch and then whenever the 24-hour throttle allows, while the app runs.
/// `CMACC_NO_UPDATE_CHECK=1` (or `true`/`yes`) turns it off entirely: no file read, no request.
@MainActor
public final class ReleaseNotice {
  public static let environmentKey = "CMACC_NO_UPDATE_CHECK"
  public static let firstCheckDelay: Duration = .seconds(60)

  /// The newer release to offer, or nil.
  public private(set) var available: AppReleaseInfo?
  /// Called on the main actor after `available` changed.
  public var onChange: (() -> Void)?

  private let checker: ReleaseChecker
  private let isDisabled: Bool
  private let sleep: @Sendable (Duration) async throws -> Void
  private let log = AppLog.logger("release-check")
  private(set) var loop: Task<Void, Never>?

  /// `sleep` throwing (e.g. on cancellation) ends the loop.
  public init(
    checker: ReleaseChecker, isDisabled: Bool = false,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.checker = checker
    self.isDisabled = isDisabled
    self.sleep = sleep
  }

  /// The live notice: state in `paths.releaseCheckFile`, version from the bundle's `CFBundleShortVersionString`.
  public static func live(
    paths: Paths = .live(), environment: [String: String] = ProcessInfo.processInfo.environment,
    infoDictionary: [String: Any]? = Bundle.main.infoDictionary
  ) -> ReleaseNotice {
    let version = runningVersion(infoDictionary: infoDictionary)
    let checker = ReleaseChecker(
      stateFile: paths.releaseCheckFile, fetcher: GitHubReleaseFetcher(appVersion: version), currentVersion: version)
    return ReleaseNotice(checker: checker, isDisabled: isDisabled(environment: environment))
  }

  /// Whether `CMACC_NO_UPDATE_CHECK` asks to skip the check (`1`, `true` or `yes`, any case).
  public static func isDisabled(environment: [String: String]) -> Bool {
    guard let value = environment[environmentKey]?.lowercased() else { return false }
    return ["1", "true", "yes"].contains(value)
  }

  /// `CFBundleShortVersionString`, else `BuildInfo.version` (e.g. under `swift run`).
  static func runningVersion(infoDictionary: [String: Any]?) -> String {
    infoDictionary?["CFBundleShortVersionString"] as? String ?? BuildInfo.version
  }

  /// Starts the check loop once; later calls do nothing.
  public func start() {
    guard loop == nil else { return }
    guard !isDisabled else {
      log.info("Release check disabled by \(Self.environmentKey, privacy: .public)")
      return
    }
    let checker = checker
    let sleep = sleep
    loop = Task { [weak self] in
      let cached = await checker.cached()
      self?.publish(cached)
      var wait = Self.firstCheckDelay
      while !Task.isCancelled {
        do {
          try await sleep(wait)
        } catch {
          return
        }
        let outcome = await checker.checkIfDue()
        guard let self, !Task.isCancelled else { return }
        self.publish(outcome.available)
        wait = outcome.wait
      }
    }
  }

  /// Cancels the loop; `available` keeps its last value.
  public func stop() {
    loop?.cancel()
    loop = nil
  }

  private func publish(_ release: AppReleaseInfo?) {
    guard release != available else { return }
    available = release
    onChange?()
  }
}
