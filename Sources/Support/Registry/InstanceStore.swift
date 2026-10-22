import Foundation

public enum InstanceStoreError: Error, Equatable {
  /// `instances.json` exists but cannot be decoded; it is never overwritten.
  case corrupt(path: String)
  case notFound(String)
}

public enum InstanceValidationError: Error, Equatable, Sendable {
  case duplicateSlug(String)
  case duplicateBundleId(String)
  case duplicateAppPath(String)
  case duplicateProfileDir(String)
  case badSlug(String)
  case emptyName
  /// `instances.json` exists but cannot be decoded, so nothing can be checked (the path is attached).
  case storeCorrupt(String)
}

/// Serialises reads and atomic writes (0600) of `instances.json`, the ordered single source of truth (G20).
public actor InstanceStore {
  private struct File: Codable {
    let schemaVersion: Int
    let instances: [Instance]
  }

  private let paths: Paths

  public init(paths: Paths) {
    self.paths = paths
  }

  /// Reads the list; when the file is missing, returns the seeds without writing them.
  public func load() throws -> [Instance] {
    guard FileManager.default.fileExists(atPath: paths.instancesFile.path) else {
      return InstanceSeeds.seeds(home: paths.home)
    }
    do {
      return try JSONCoding.decoder.decode(File.self, from: Data(contentsOf: paths.instancesFile)).instances
    } catch {
      throw InstanceStoreError.corrupt(path: paths.instancesFile.path)
    }
  }

  /// Reads the list, writing the seeds first when the file is missing.
  public func loadOrSeed() throws -> [Instance] {
    let exists = FileManager.default.fileExists(atPath: paths.instancesFile.path)
    let instances = try load()
    if !exists { try save(instances) }
    return instances
  }

  public func save(_ instances: [Instance]) throws {
    let data = try JSONCoding.encoder.encode(File(schemaVersion: 1, instances: instances))
    try AtomicFile.write(data, to: paths.instancesFile, permissions: 0o600)
  }

  /// Replaces the instance with the same slug in place, else appends it.
  public func upsert(_ i: Instance) throws -> [Instance] {
    let current = try loadOrSeed()
    let updated = current.contains { $0.slug == i.slug }
      ? current.map { $0.slug == i.slug ? i : $0 }
      : current + [i]
    try save(updated)
    return updated
  }

  public func remove(slug: Slug) throws -> [Instance] {
    let current = try loadOrSeed()
    guard current.contains(where: { $0.slug == slug }) else { throw InstanceStoreError.notFound(slug.raw) }
    let updated = current.filter { $0.slug != slug }
    try save(updated)
    return updated
  }

  /// Moves the instance to `index` (clamped to the list bounds).
  public func move(slug: Slug, to index: Int) throws -> [Instance] {
    let current = try loadOrSeed()
    guard let moving = current.first(where: { $0.slug == slug }) else { throw InstanceStoreError.notFound(slug.raw) }
    var rest = current.filter { $0.slug != slug }
    rest.insert(moving, at: min(max(0, index), rest.count))
    try save(rest)
    return rest
  }

  /// Problems that prevent adding `i` next to the current list. A corrupt list yields only `.storeCorrupt`.
  public func validateNew(_ i: Instance) -> [InstanceValidationError] {
    let existing: [Instance]
    do {
      existing = try load()
    } catch {
      return [.storeCorrupt(paths.instancesFile.path)]
    }
    var errors: [InstanceValidationError] = []
    if !Slug.isValid(i.slug.raw) { errors.append(.badSlug(i.slug.raw)) }
    if existing.contains(where: { $0.slug == i.slug }) { errors.append(.duplicateSlug(i.slug.raw)) }
    if let v = i.bundleId, existing.contains(where: { $0.bundleId == v }) { errors.append(.duplicateBundleId(v)) }
    if let v = i.appPath, existing.contains(where: { $0.appPath == v }) { errors.append(.duplicateAppPath(v)) }
    if let v = i.profileDir, existing.contains(where: { $0.profileDir == v }) { errors.append(.duplicateProfileDir(v)) }
    if i.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.emptyName) }
    return errors
  }
}
