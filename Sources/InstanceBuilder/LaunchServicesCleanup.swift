import Foundation
import os
import Support

/// LaunchServices hygiene for bundles that only live in the data folder. Every swap moves the previous bundle to
/// `<data>/backup/`, and LaunchServices keeps it (and the helper apps inside it) registered, so a bundle id, a
/// `claude://` link, Open With or Spotlight can resolve to that hidden copy; staged builds can be picked up the same way.
public enum LaunchServicesCleanup {
  /// The bundle table of the read-only database dump (about half the size of the whole dump).
  static let dumpArguments = ["-dump", "Bundle"]
  /// How deep below the staging folder a staged `*.app` is looked for (`<slug>-<ts>.noindex/<name>.app` is 2).
  static let stagingDepth = 3
  private static let log = AppLog.logger("launchservices")

  /// `<logs>/updates.log`, where swaps and this cleanup report.
  static func updatesLog(_ paths: Paths) -> URL { paths.logsDir.appendingPathComponent("updates.log") }

  /// Once at app start: `lsregister -u` for every backup (and each app inside a `failed-<ts>/` folder), every staged
  /// `*.app`, and every bundle the LaunchServices database still lists under the backup or staging folder (nested
  /// helpers and deleted backups included) or anywhere else under the data folder while gone from disk. Idempotent and
  /// quiet: never throws, deletes nothing, follows no symlink, touches nothing outside the data folder, and writes one
  /// summary line to updates.log.
  /// `lsregister -u` on a bundle LaunchServices does not know ("failed to scan …: -10814"): nothing to forget.
  static let notRegisteredCode = "-10814"

  public static func sweep(paths: Paths, runner: ProcessRunning) async {
    let inside = { (url: URL) in isInside(url, paths.dataDir) }
    let backups = backupBundles(in: paths.backupDir).filter(inside)
    let staged = stagedBundles(in: paths.stagingDir, depth: stagingDepth).filter(inside)
    let dump = await databasePaths(runner: runner)
    let onDisk = Set((backups + staged).map(\.path))
    let database = staleRecords(dump.paths, paths: paths).filter { !onDisk.contains($0.path) }
    let targets = backups + staged + database
    let registrar = Registrar(runner: runner, staging: nil)
    var failures: [String] = []
    var notRegistered = 0
    for app in targets {
      do {
        try await registrar.unregister(app)
      } catch let BuilderError.commandFailed(_, _, stderr) where stderr.contains(notRegisteredCode) {
        notRegistered += 1
      } catch {
        failures.append("\(app.lastPathComponent) (\(error))")
      }
    }
    let done = targets.count - failures.count - notRegistered
    var line = "launchservices sweep: unregistered \(done) of \(targets.count) "
      + "(backups \(backups.count), staged \(staged.count), database \(database.count))"
    if notRegistered > 0 { line += "; \(notRegistered) not registered" }
    if let note = dump.note { line += "; dump: \(note)" }
    if let first = failures.first { line += "; failed \(failures.count): \(first)" }
    await RedactingFileLog(url: updatesLog(paths)).write(line, category: "updates")
  }

  // MARK: On disk

  /// Each bundle directly in the backup folder, and each `*.app` inside a folder there that is no bundle itself
  /// (`failed-<ts>/`). Real directories only.
  static func backupBundles(in backupDir: URL) -> [URL] {
    children(of: backupDir).flatMap { entry -> [URL] in
      guard isRealDirectory(entry) else { return [] }
      if isRealDirectory(entry.appendingPathComponent("Contents")) { return [entry] }
      return children(of: entry).filter { $0.pathExtension == "app" && isRealDirectory($0) }
    }
  }

  /// `*.app` bundles up to `depth` levels below `dir`; never descends into a bundle or follows a symlink.
  static func stagedBundles(in dir: URL, depth: Int) -> [URL] {
    guard depth > 0 else { return [] }
    return children(of: dir).flatMap { child -> [URL] in
      guard isRealDirectory(child) else { return [] }
      return child.pathExtension == "app" ? [child] : stagedBundles(in: child, depth: depth - 1)
    }
  }

  // MARK: The LaunchServices database

  /// Record paths from the read-only `lsregister -dump Bundle`; none, with a note, when it fails. A dump cut short by
  /// the runner's output limit still yields the records it holds.
  static func databasePaths(runner: ProcessRunning) async -> (paths: [String], note: String?) {
    let result: ProcessResult
    do {
      result = try await runner.runTool(BuilderTool.lsregister, dumpArguments, timeout: BuilderTool.shortTimeout)
    } catch {
      return ([], String(describing: error))
    }
    guard result.exitCode == 0 else { return ([], "lsregister exited \(result.exitCode)") }
    let note = result.stdoutTruncated ? "output truncated, later records unchecked" : nil
    return (registeredPaths(inDump: result.stdout), note)
  }

  /// Database records worth forgetting, sorted and unique: everything under the backup or staging folder, and anything
  /// else under the data folder that is gone from disk (a dangling symlink still counts as present).
  static func staleRecords(_ registered: [String], paths: Paths) -> [URL] {
    Set(registered).sorted().map { URL(fileURLWithPath: $0) }.filter { url in
      guard isInside(url, paths.dataDir) else { return false }
      return isInside(url, paths.backupDir) || isInside(url, paths.stagingDir) || !exists(url)
    }
  }

  /// The `path:` lines of an `lsregister -dump`: `path:<spaces><absolute path> (0x<record id>)` at the start of a
  /// line. Any other line, and a path line without the trailing record id or with a relative path, is ignored.
  static func registeredPaths(inDump dump: Data) -> [String] {
    let marker = Array("path:".utf8)
    return dump.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String] in
      guard let base = raw.baseAddress else { return [] }
      var found: [String] = []
      var start = 0
      while start < raw.count {
        let newline: UnsafeMutableRawPointer? = memchr(base + start, 0x0A, raw.count - start)
        let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
        let line = UnsafeRawBufferPointer(rebasing: raw[start..<end])
        if line.starts(with: marker),
           let path = recordPath(String(decoding: line.dropFirst(marker.count), as: UTF8.self)) {
          found.append(path)
        }
        start = end + 1
      }
      return found
    }
  }

  /// `<spaces><absolute path> (0x<hex>)` → the path; nil for any other shape.
  private static func recordPath(_ rest: String) -> String? {
    guard let id = rest.range(of: #" \(0x[0-9A-Fa-f]+\)$"#, options: .regularExpression) else { return nil }
    let path = String(rest[..<id.lowerBound].drop { $0 == " " || $0 == "\t" })
    return path.hasPrefix("/") ? path : nil
  }

  // MARK: Paths

  /// Whether `url` lies inside `dir`, both as written and with symlinks resolved (a link that leads out is outside).
  static func isInside(_ url: URL, _ dir: URL) -> Bool {
    guard url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else { return false }
    return StagingArea.resolvedPath(url).hasPrefix(StagingArea.resolvedPath(dir) + "/")
  }

  /// Entries of a real directory, sorted by name; none for a missing directory or a symlink.
  private static func children(of dir: URL) -> [URL] {
    guard isRealDirectory(dir) else { return [] }
    do {
      return try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        .map { dir.appendingPathComponent($0, isDirectory: true) }
    } catch {
      log.error("cannot list \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
      return []
    }
  }

  /// `lstat`-based: symlinks are never "real directories".
  private static func isRealDirectory(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }

  private static func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
  }
}
