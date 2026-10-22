import Foundation
import Support
import Synchronization

/// Keeps ClaudeMultiAcc's own Claude current without the official app's updater: asks the Claude feed for something
/// newer than the newest source, downloads the full archive into `<data>/source/incoming.noindex/`, has it verified and
/// stored (`ClaudeSourceInstalling`) and announces the new source so the clones are rebuilt from it.
///
/// Runs `startDelay` after `start()`, then every `interval` (unless `CMACC_NO_CLAUDE_UPDATE_CHECK=1`), and on the
/// menu's ↻ (`checkNow(manual: true)`). Overlapping calls share one pass. Only a manual check ends in `upToDate` or
/// `failed`; an automatic one goes back to `idle` and only logs. Every pass writes one line to `<logs>/updates.log`
/// (category `claude-update`). Without the official app nothing is requested (`officialMissing`).
public actor ClaudeUpdateChecker: ClaudeUpdateChecking {
  public static let startDelay: Duration = .seconds(60)
  public static let interval: Duration = .seconds(6 * 60 * 60)
  /// Free bytes the data volume needs before a download: the archive, the unpacked app and a clone build.
  public static let requiredFreeBytes: Int64 = 2_000_000_000
  /// `=1` turns off the automatic checks; ↻ still works.
  public static let disableVariable = "CMACC_NO_CLAUDE_UPDATE_CHECK"
  static let archiveName = "Claude.zip"
  static let logCategory = "claude-update"

  let paths: Paths
  let store: ClaudeSourceStore
  let feed: any ClaudeFeedFetching
  let downloader: any ClaudeArchiveDownloading
  let installer: any ClaudeSourceInstalling
  let osVersion: String
  let freeSpace: @Sendable (URL) -> Int64?
  let automaticChecksDisabled: Bool
  let sleep: @Sendable (Duration) async -> Void
  let log: RedactingFileLog
  private let systemLog = AppLog.logger("claude-update")

  /// What the menu shows; every real change goes to the `onStatusChange` handler exactly once.
  public private(set) var status: ClaudeUpdateStatus = .idle
  private var statusChanged: (@Sendable (ClaudeUpdateStatus) -> Void)?
  private var newSource: (@Sendable (ClaudeSource) async -> Void)?
  private var timer: Task<Void, Never>?
  private var inFlight: Task<ClaudeUpdateStatus, Never>?
  /// A manual call started or joined the running pass: it ends in `upToDate`/`failed` rather than `idle`.
  private(set) var passIsManual = false
  /// `stop()` ran (the app quits): a pass that still stores its download does not announce it, so no rebuild starts
  /// that quitting would cut short; the next launch's update pass picks the stored version up.
  private var stopped = false

  public init(
    paths: Paths, store: ClaudeSourceStore, feed: any ClaudeFeedFetching, downloader: any ClaudeArchiveDownloading,
    installer: any ClaudeSourceInstalling, osVersion: String = ClaudeUpdateChecker.systemVersion(),
    freeSpace: @escaping @Sendable (URL) -> Int64? = ClaudeUpdateChecker.availableCapacity,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.paths = paths
    self.store = store
    self.feed = feed
    self.downloader = downloader
    self.installer = installer
    self.osVersion = osVersion
    self.freeSpace = freeSpace
    automaticChecksDisabled = environment[Self.disableVariable] == "1"
    self.sleep = sleep
    log = RedactingFileLog(url: paths.logsDir.appendingPathComponent("updates.log"))
  }

  /// Called on the checker's executor for every status change; hop to the main actor inside.
  public func onStatusChange(_ handler: @escaping @Sendable (ClaudeUpdateStatus) -> Void) {
    statusChanged = handler
  }

  /// Called once per stored download (after the status turned `ready`); the pass waits for it, but `stop()` never
  /// cancels it, so a clone rebuild it starts is not cut short.
  public func onNewSource(_ handler: @escaping @Sendable (ClaudeSource) async -> Void) {
    newSource = handler
  }

  /// The automatic checks are scheduled.
  var isScheduled: Bool { timer != nil }

  /// Schedules the automatic checks: one after `startDelay`, then one every `interval`. A second call is a no-op.
  public func start() {
    stopped = false
    guard timer == nil else { return }
    guard !automaticChecksDisabled else {
      systemLog.notice("Automatic Claude update checks are off (\(Self.disableVariable, privacy: .public)=1)")
      return
    }
    timer = Task { await self.runSchedule() }
  }

  /// Cancels the timer and a running pass (its download stops; `incoming.noindex` is wiped).
  public func stop() {
    stopped = true
    timer?.cancel()
    timer = nil
    inFlight?.cancel()
  }

  /// One pass, or the running one joined; returns the status it ended in. A manual call makes the shared pass manual.
  public func checkNow(manual: Bool) async -> ClaudeUpdateStatus {
    passIsManual = passIsManual || manual
    if let inFlight { return await inFlight.value }
    let pass = Task { await self.runPass() }
    inFlight = pass
    return await pass.value
  }

  /// `major.minor.patch` of the running macOS, the feed's `os_version`.
  public static func systemVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
  }

  /// Free bytes for important use on `dir`'s volume; when `dir` does not exist yet it is created (0700) and read
  /// again. nil when unknown (the download then goes ahead).
  @Sendable public static func availableCapacity(_ dir: URL) -> Int64? {
    if let free = volumeCapacity(dir) { return free }
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return volumeCapacity(dir)
  }

  private static func volumeCapacity(_ dir: URL) -> Int64? {
    let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  private func runSchedule() async {
    await sleep(Self.startDelay)
    while !Task.isCancelled {
      _ = await checkNow(manual: false)
      await sleep(Self.interval)
    }
  }

  /// The pass is over (and joinable no more) before the log line and the announcement, so a ↻ during a rebuild
  /// starts a check of its own instead of getting an older result.
  private func runPass() async -> ClaudeUpdateStatus {
    publish(.checking)
    let (outcome, pruned) = await check()
    wipeIncomingAfterPass()
    let manual = passIsManual
    let final = outcome.status(manual: manual)
    inFlight = nil
    passIsManual = false
    publish(final)
    let line = [outcome.line, pruned].compactMap { $0 }.joined(separator: "; ") + (manual ? " (manual)" : "")
    await log.write(line, category: Self.logCategory)
    if case .stored(_, let source) = outcome, let newSource, !stopped {
      // Its own task: cancelling the pass must not reach into the rebuild it starts.
      await Task { await newSource(source) }.value
    }
    return final
  }

  /// The pass up to its outcome, plus a note about superseded downloads removed on the way.
  private func check() async -> (ClaudeUpdateOutcome, pruned: String?) {
    guard store.official() != nil else { return (.failed(.officialMissing), nil) }
    let pruned = pruneSuperseded()
    do {
      return (try await fetchAndStore(), pruned)
    } catch {
      if Task.isCancelled { return (.cancelled, pruned) }
      return (.failed((error as? ClaudeUpdateFailure) ?? .network(String(describing: error))), pruned)
    }
  }

  private func fetchAndStore() async throws -> ClaudeUpdateOutcome {
    guard let current = store.newest()?.version else { throw ClaudeUpdateFailure.officialMissing }
    let deviceId = try ClaudeUpdateState.deviceId(in: paths.claudeUpdateFile)
    let answer = try await feed.latest(current: current, deviceId: deviceId, osVersion: osVersion)
    guard case .available(let release) = answer else { return .upToDate(current) }
    try Self.vet(release)
    guard VersionCompare.isNewer(release.version, than: current) else { return .upToDate(current) }
    if !passIsManual, ClaudeUpdateState.isRejected(release, in: paths.claudeUpdateFile) {
      return .skippedRejected(release.version)
    }
    if let free = freeSpace(paths.dataDir), free < Self.requiredFreeBytes {
      throw ClaudeUpdateFailure.notEnoughSpace(free: free, needed: Self.requiredFreeBytes)
    }
    let archive = try freshIncoming().appendingPathComponent(Self.archiveName)
    do {
      try await download(release, to: archive)
      publish(.verifying(version: release.version))
      return .stored(from: current, try await installer.install(archive: archive, release: release))
    } catch let failure as ClaudeUpdateFailure where failure.isAboutTheArchive {
      remember(rejected: release)
      throw failure
    }
  }

  /// A failure the same archive would meet again: the automatic checks skip it from now on.
  private func remember(rejected release: ClaudeRelease) {
    do {
      try ClaudeUpdateState.reject(release, in: paths.claudeUpdateFile)
    } catch {
      systemLog.error("Cannot remember the rejected Claude archive: \(String(describing: error), privacy: .public)")
    }
  }

  /// The feed vets its answer too; a bad version here would also be a slot name, a bad URL a download.
  private static func vet(_ release: ClaudeRelease) throws {
    guard ClaudeSourceStore.isValidVersion(release.version) else {
      throw ClaudeUpdateFailure.badAnswer("invalid version \(release.version)")
    }
    guard ClaudeDownloadPolicy.isAllowed(release.url) else {
      throw ClaudeUpdateFailure.untrustedURL(release.url.absoluteString)
    }
  }

  /// Downloads with `downloading(version, percent)` for every new whole percent, in order: the progress callback
  /// feeds a stream that this actor drains before the download counts as done.
  private func download(_ release: ClaudeRelease, to archive: URL) async throws {
    publish(.downloading(version: release.version, percent: 0))
    let (percents, sink) = AsyncStream.makeStream(of: Int.self)
    let relay = Task { await self.relay(percents, version: release.version) }
    let gate = PercentGate()
    do {
      try await downloader.download(release, to: archive) { fraction in
        if let percent = gate.change(to: fraction) { sink.yield(percent) }
      }
    } catch {
      sink.finish()
      await relay.value
      throw error
    }
    sink.finish()
    await relay.value
  }

  private func relay(_ percents: AsyncStream<Int>, version: String) async {
    for await percent in percents { publish(.downloading(version: version, percent: percent)) }
  }

  private func publish(_ new: ClaudeUpdateStatus) {
    guard new != status else { return }
    status = new
    statusChanged?(new)
  }

  /// Downloads the official app caught up with go, under a non-blocking `update.lock` (kept while a pass holds it).
  private func pruneSuperseded() -> String? {
    guard case .acquired(let lock) = UpdateLock.acquire(UpdateLock.file(paths)) else { return nil }
    defer { lock.release() }
    do {
      let removed = try store.pruneSuperseded()
      guard !removed.isEmpty else { return nil }
      return "removed superseded " + removed.map { $0.deletingPathExtension().lastPathComponent }.joined(separator: ", ")
    } catch {
      return "cannot remove superseded downloads: \(error)"
    }
  }

  /// An empty `incoming.noindex` for the download (anything left from an interrupted one goes first).
  private func freshIncoming() throws -> URL {
    let dir = store.incomingDir
    do {
      try Self.remove(dir)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw ClaudeUpdateFailure.storage("cannot prepare \(dir.lastPathComponent): \(error)")
    }
    return dir
  }

  /// After every pass, success or failure: the archive and the unpacked copy are never kept.
  private func wipeIncomingAfterPass() {
    do {
      try Self.remove(store.incomingDir)
    } catch {
      systemLog.error("Cannot remove incoming Claude download: \(String(describing: error), privacy: .public)")
    }
  }

  /// Removes `url` if anything is there (a symlink as a link, never followed).
  private static func remove(_ url: URL) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return }
    try FileManager.default.removeItem(at: url)
  }
}

extension ClaudeUpdateFailure {
  /// The archive itself is wrong (size, checksum, contents, signature, version): downloading it again would not help.
  var isAboutTheArchive: Bool {
    switch self {
    case .sizeMismatch, .checksumMismatch, .unpackFailed, .notGenuine, .versionMismatch: true
    default: false
    }
  }
}

/// Turns download fractions into whole percents and passes on only changes (a download reports far more often).
private final class PercentGate: Sendable {
  private let last = Mutex(0)

  func change(to fraction: Double) -> Int? {
    guard fraction.isFinite else { return nil }
    let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    return last.withLock { last in
      guard percent != last else { return nil }
      last = percent
      return percent
    }
  }
}
