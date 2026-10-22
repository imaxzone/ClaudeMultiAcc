import Foundation
import os
import Support

/// The `instances.json` list that the menu, the sign-in router and the actions read synchronously. Loaded (and
/// seeded on the first run) by `start()`, reloaded when the file changes on disk (the update watcher, `cmacc`, the
/// editor) or when asked. A file that cannot be read keeps the last good list.
@MainActor
public final class InstanceList {
  public private(set) var instances: [Instance] = []
  /// Runs after every reload, also when nothing changed.
  public var onChange: (() -> Void)?

  private let store: InstanceStore
  private let dataDir: URL
  private let fileName: String
  private var watcher: DirectoryWatcher?
  private let log = AppLog.logger("instances")

  public init(paths: Paths) {
    store = InstanceStore(paths: paths)
    dataDir = paths.dataDir
    fileName = paths.instancesFile.lastPathComponent
  }

  /// Watches first, then loads: a change in between is not missed.
  public func start() async {
    let name = fileName
    let watcher = DirectoryWatcher(paths: [dataDir], latency: 1.0) { [weak self] urls in
      guard urls.contains(where: { $0.lastPathComponent == name }) else { return }
      Task { @MainActor in await self?.reload() }
    }
    watcher.start()
    self.watcher = watcher
    await reload()
  }

  public func stop() {
    watcher?.stop()
    watcher = nil
  }

  public func reload() async {
    do {
      instances = try await store.loadOrSeed()
    } catch {
      log.error("Cannot read instances.json: \(String(describing: error), privacy: .public)")
    }
    onChange?()
  }

  public func instance(slug: String) -> Instance? {
    instances.first { $0.slug.raw == slug }
  }
}
