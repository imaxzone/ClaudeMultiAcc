import Foundation
import Support

/// `<data>/staging/<slug>-<yyyyMMdd-HHmmss>.noindex/` build directories (G12).
public struct StagingArea: Sendable {
  private let paths: Paths
  private let timeZone: TimeZone

  public init(paths: Paths, timeZone: TimeZone? = nil) {
    self.paths = paths
    self.timeZone = timeZone ?? .current
  }

  public var root: URL { paths.stagingDir }

  /// Creates a fresh private (0700) build dir; refuses to reuse an existing one.
  public func newBuildDir(slug: Slug, now: Date) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dir = root.appendingPathComponent("\(slug.raw)-\(stamp(now)).noindex", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: dir.path) else { throw BuilderError.buildDirExists(dir.path) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    return dir
  }

  /// Build dirs of `slug`, oldest first (the timestamp sorts lexicographically).
  public func builds(slug: Slug) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    let pattern = "^\(NSRegularExpression.escapedPattern(for: slug.raw))-[0-9]{8}-[0-9]{6}\\.noindex$"
    return try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.range(of: pattern, options: .regularExpression) != nil }
      .sorted()
      .map { root.appendingPathComponent($0, isDirectory: true) }
  }

  /// Removes every build dir of `slug`. Validates all of them first and deletes nothing if any is a symlink,
  /// not a directory, or not directly inside the real staging dir.
  public func discard(slug: Slug) throws -> Int {
    let dirs = try builds(slug: slug)
    for dir in dirs { try validate(dir) }
    for dir in dirs { try FileManager.default.removeItem(at: dir) }
    return dirs.count
  }

  /// Whether `url` lies inside the staging dir (used to refuse icon queries or launches of staged bundles).
  /// Symlinks are resolved on both sides, so a link pointing into staging still counts as inside.
  public func contains(_ url: URL) -> Bool {
    let base = Self.resolvedPath(root) + "/"
    return Self.resolvedPath(url).hasPrefix(base)
  }

  /// The path with symlinks resolved in its deepest existing ancestor (Foundation leaves paths whose
  /// last components do not exist unresolved), then the missing components re-appended.
  static func resolvedPath(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
      missing.insert(existing.lastPathComponent, at: 0)
      existing = existing.deletingLastPathComponent()
    }
    let resolved = missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    return resolved.standardizedFileURL.path
  }

  private func validate(_ dir: URL) throws {
    guard isRealDirectory(root.path) else { throw BuilderError.stagingPathRefused(root.path) }
    guard isRealDirectory(dir.path), dir.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
    else { throw BuilderError.stagingPathRefused(dir.path) }
  }

  /// `lstat`-based: symlinks are never "real directories".
  private func isRealDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }

  private func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
