import CryptoKit
import Foundation
import os
import Support

/// Turns a downloaded Claude archive into a stored source: size and SHA-256 against the feed, `ditto -x -k` into
/// `incoming.noindex/unpacked`, exactly one `Claude.app`, quarantine removed, `SourceProbe` (Anthropic's Team ID, the
/// vendor bundle id, `codesign --verify --strict`) and the feed's version. Only then, under `update.lock`, the app
/// moves into `<version>.noindex` by a rename on the same volume and every other download is pruned. A slot is never
/// seen half-filled: it is assembled under a hidden name in the store and renamed into place. Writes nothing outside
/// `store.root` (except taking `update.lock`); the archive itself is left for the caller to wipe.
public struct ClaudeSourceInstaller: ClaudeSourceInstalling {
  /// `update.lock` is retried for two minutes (an update pass may be rebuilding clones), then `.busy`.
  static let lockAttempts = 24
  static let lockRetry: Duration = .seconds(5)
  static let unpackedName = "unpacked"
  /// Hidden directories in the store a slot is assembled in; a crash can leave one, removed by the next install.
  static let assemblyPrefix = ".installing-"
  static let hashChunk = 1 << 20

  private let paths: Paths
  private let store: ClaudeSourceStore
  private let runner: ProcessRunning
  private let policy: SourcePolicy
  private let sleep: @Sendable (Duration) async -> Void
  private let log = AppLog.logger("claude-update")

  public init(
    paths: Paths, store: ClaudeSourceStore, runner: ProcessRunning, policy: SourcePolicy = .vendor,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.paths = paths
    self.store = store
    self.runner = runner
    self.policy = policy
    self.sleep = sleep
  }

  /// Throws `ClaudeUpdateFailure`; on any failure the store is as it was and `unpacked` is gone.
  public func install(archive: URL, release: ClaudeRelease) async throws -> ClaudeSource {
    guard ClaudeSourceStore.isValidVersion(release.version) else {
      throw ClaudeUpdateFailure.badAnswer("invalid version \(release.version)")
    }
    let size = try Self.size(of: archive)
    guard size == release.size else { throw ClaudeUpdateFailure.sizeMismatch(expected: release.size, actual: size) }
    guard try Self.sha256(of: archive) == release.sha256.lowercased() else { throw ClaudeUpdateFailure.checksumMismatch }

    let unpacked = store.incomingDir.appendingPathComponent(Self.unpackedName, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: unpacked) }
    let app = try await unpack(archive, into: unpacked)
    try await verify(app, release: release)
    return try await moveIntoStore(app, version: release.version)
  }

  // MARK: archive

  static func size(of archive: URL) throws -> Int64 {
    var info = stat()
    guard stat(archive.path, &info) == 0 else {
      throw ClaudeUpdateFailure.storage("cannot read \(archive.lastPathComponent) (errno \(errno))")
    }
    return Int64(info.st_size)
  }

  /// Lowercase hex SHA-256, read in `hashChunk` pieces (the archive is a quarter of a gigabyte).
  static func sha256(of file: URL) throws -> String {
    let fd = open(file.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw ClaudeUpdateFailure.storage("cannot open \(file.lastPathComponent) (errno \(errno))") }
    defer { close(fd) }
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: hashChunk, alignment: 16)
    defer { buffer.deallocate() }
    var hasher = SHA256()
    while true {
      let count = read(fd, buffer.baseAddress, hashChunk)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw ClaudeUpdateFailure.storage("cannot read \(file.lastPathComponent) (errno \(errno))")
      }
      hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<count]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// `ditto -x -k <archive> <dir>` into a fresh `dir`; returns its one top-level `Claude.app`.
  private func unpack(_ archive: URL, into dir: URL) async throws -> URL {
    do {
      try? FileManager.default.removeItem(at: dir)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    } catch {
      throw ClaudeUpdateFailure.storage(String(describing: error))
    }
    let result: ProcessResult
    do {
      result = try await runner.runTool(BuilderTool.ditto, ["-x", "-k", archive.path, dir.path], timeout: BuilderTool.copyTimeout)
    } catch {
      throw ClaudeUpdateFailure.unpackFailed(String(describing: error))
    }
    guard result.exitCode == 0 else {
      throw ClaudeUpdateFailure.unpackFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return try Self.singleApp(in: dir)
  }

  /// The archive must hold exactly one app at its top, a real directory named `Claude.app`.
  static func singleApp(in dir: URL) throws -> URL {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    let apps = names.filter { $0.lowercased().hasSuffix(".app") }.sorted()
    guard apps == [ClaudeSourceStore.appName] else {
      throw ClaudeUpdateFailure.unpackFailed("expected one \(ClaudeSourceStore.appName), found \(apps)")
    }
    let app = dir.appendingPathComponent(ClaudeSourceStore.appName, isDirectory: true)
    guard ClaudeSourceStore.isRealDirectory(app) else {
      throw ClaudeUpdateFailure.unpackFailed("\(ClaudeSourceStore.appName) is not a directory")
    }
    return app
  }

  // MARK: checks

  /// Quarantine off (the download may carry it), then Anthropic's signature and the feed's version.
  private func verify(_ app: URL, release: ClaudeRelease) async throws {
    do {
      try Quarantine.remove(from: app)
    } catch {
      throw ClaudeUpdateFailure.storage(String(describing: error))
    }
    let info: SourceInfo
    do {
      info = try await SourceProbe(runner: runner, policy: policy).probe(app)
    } catch {
      throw ClaudeUpdateFailure.notGenuine(String(describing: error))
    }
    guard info.version == release.version else {
      throw ClaudeUpdateFailure.versionMismatch(expected: release.version, found: info.version)
    }
    try await verifyDeep(app)
  }

  /// Signed through Apple by `team` (Anthropic's for the vendor policy), the app and everything inside it.
  static func requirement(team: String) -> String {
    #"anchor apple generic and certificate leaf[subject.OU] = "\#(team)""#
  }

  /// `codesign --verify --deep --strict` against `requirement`: unlike the probe's Team ID (read from `codesign -dv`
  /// text), this ties the signature to Apple's chain and covers nested code. Skipped by the test policy (no team).
  private func verifyDeep(_ app: URL) async throws {
    guard let team = policy.expectedTeamId else { return }
    let arguments = ["--verify", "--deep", "--strict", "-R=\(Self.requirement(team: team))", app.path]
    let result: ProcessResult
    do {
      result = try await runner.runTool(BuilderTool.codesign, arguments, timeout: BuilderTool.signTimeout)
    } catch {
      throw ClaudeUpdateFailure.notGenuine(String(describing: error))
    }
    guard result.exitCode == 0 else {
      throw ClaudeUpdateFailure.notGenuine(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  // MARK: store

  private func moveIntoStore(_ app: URL, version: String) async throws -> ClaudeSource {
    let lock = try await acquireLock()
    defer { lock.release() }
    let slot = store.slot(for: version)
    do {
      try place(app, at: slot)
    } catch let failure as ClaudeUpdateFailure {
      throw failure
    } catch {
      throw ClaudeUpdateFailure.storage(String(describing: error))
    }
    do {
      let removed = try store.prune(keeping: version)
      if !removed.isEmpty { log.info("pruned \(removed.count, privacy: .public) older Claude download(s)") }
    } catch {
      // The new slot is in place and wins `downloaded()`; an old one left behind only costs space until next time.
      log.error("could not prune older Claude downloads: \(String(describing: error), privacy: .public)")
    }
    log.notice("stored Claude \(version, privacy: .public)")
    return ClaudeSource(
      app: slot.appendingPathComponent(ClaudeSourceStore.appName, isDirectory: true), version: version, isOfficial: false)
  }

  /// Moves `app` into a hidden assembly directory in the store, then renames that to `slot` in one step: exclusively
  /// when there is no slot yet, by an atomic swap when one exists (a broken earlier attempt), which then goes away
  /// under the assembly name. Hold `update.lock`.
  private func place(_ app: URL, at slot: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: store.root, withIntermediateDirectories: true)
    guard ClaudeSourceStore.isRealDirectory(store.root) else {
      throw ClaudeUpdateFailure.storage("\(store.root.path) is not a directory")
    }
    removeAbandonedAssemblies()
    let assembly = store.root.appendingPathComponent(
      Self.assemblyPrefix + UUID().uuidString + ClaudeSourceStore.slotSuffix, isDirectory: true)
    try fm.createDirectory(at: assembly, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: assembly) }
    try fm.moveItem(at: app, to: assembly.appendingPathComponent(ClaudeSourceStore.appName, isDirectory: true))
    var info = stat()
    let flag = lstat(slot.path, &info) == 0 ? RENAME_SWAP : RENAME_EXCL
    guard renamex_np(assembly.path, slot.path, UInt32(flag)) == 0 else {
      throw ClaudeUpdateFailure.storage("cannot rename into \(slot.lastPathComponent) (errno \(errno))")
    }
  }

  /// Assembly directories a crashed install left behind (never followed when they are links).
  private func removeAbandonedAssemblies() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
    for name in names where name.hasPrefix(Self.assemblyPrefix) {
      try? FileManager.default.removeItem(at: store.root.appendingPathComponent(name))
    }
  }

  /// `update.lock`, retried `lockAttempts` times `lockRetry` apart; then `.busy`. A lock file that cannot be opened
  /// at all is `.storage`.
  private func acquireLock() async throws -> UpdateLock {
    for attempt in 1...Self.lockAttempts {
      switch UpdateLock.acquire(UpdateLock.file(paths)) {
      case .acquired(let lock): return lock
      case .failed(let code): throw ClaudeUpdateFailure.storage("cannot lock update.lock (errno \(code))")
      case .busy: if attempt < Self.lockAttempts { await sleep(Self.lockRetry) }
      }
    }
    throw ClaudeUpdateFailure.busy
  }
}
