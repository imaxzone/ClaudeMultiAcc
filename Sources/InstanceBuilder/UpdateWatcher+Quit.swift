import Foundation
import Support

/// A running clone's verified build is applied as soon as that clone quits (the app forwards NSWorkspace
/// didTerminate), not only by a later FSEvents or hourly pass that happens to find it closed.
extension UpdateWatcher {
  /// If `bundleId` is a cmacc-built clone with a `pendingBuild`, waits until it is idle (not running and its
  /// `.clone.lock` free; Electron helpers can hold the lock a few seconds after the main process exits), then runs
  /// `applyPendingNow()`. Any other bundle id returns [] without a pass and without writing to updates.log.
  public func cloneDidQuit(bundleId: String) async -> [UpdateDecision] {
    guard let found = await cloneWithPendingBuild(bundleId: bundleId) else { return [] }
    let (instance, staged) = found
    let slug = instance.slug.raw
    let spec: CloneSpec
    do {
      spec = try CloneSpec.from(instance: instance)
    } catch {
      return [await record(UpdateDecision(slug: slug, action: .fail, detail: String(describing: error)))]
    }
    guard await waitUntilIdle(instance, spec: spec) else {
      let detail = "still running \(Self.quitSettle.components.seconds) s after quit; build waits at \(staged)"
      return [await record(UpdateDecision(slug: slug, action: .pendingWaiting, detail: detail))]
    }
    await log.write("quit \(slug): pending build, applying", category: "updates")
    return await applyPendingNow()
  }

  /// One applying pass that is guaranteed to be this caller's own completed pass: while `evaluate(apply: true)`
  /// returns only `.coalesced` or `.skippedLocked`, sleep and try again (bounded). Returns the decisions of the pass that ran.
  public func applyPendingNow(manual: Bool = false) async -> [UpdateDecision] {
    for _ in 1..<Self.applyAttempts {
      // A pass of this watcher is waited out rather than joined: coalescing would hand its result to that pass.
      if !isEvaluating {
        let decisions = await evaluate(apply: true, manual: manual)
        if !Self.isDeferred(decisions) { return decisions }
      }
      await sleep(Self.applyRetry)
    }
    return await evaluate(apply: true, manual: manual)
  }

  /// Only `coalesced` or `skipped-locked`: no pass of this caller ran.
  static func isDeferred(_ decisions: [UpdateDecision]) -> Bool {
    !decisions.isEmpty && decisions.allSatisfy { $0.action == .coalesced || $0.action == .skippedLocked }
  }

  /// The cmacc-built clone with this bundle id and its `pendingBuild`; nil for any other app.
  private func cloneWithPendingBuild(bundleId: String) async -> (Instance, String)? {
    let instances: [Instance]
    do {
      instances = try await store.load()
    } catch {
      await log.write("fail all: cannot read instances.json: \(error)", category: "updates")
      return nil
    }
    let clone = instances.first { $0.kind == .clone && $0.builtBy == "cmacc" && $0.bundleId == bundleId }
    guard let clone, let staged = clone.pendingBuild else { return nil }
    return (clone, staged)
  }

  /// Polls every `idlePoll`; false when the clone still runs `quitSettle` after the quit.
  private func waitUntilIdle(_ instance: Instance, spec: CloneSpec) async -> Bool {
    for _ in 0..<Int(Self.quitSettle / Self.idlePoll) {
      if await isIdle(instance, spec: spec) { return true }
      await sleep(Self.idlePoll)
    }
    return await isIdle(instance, spec: spec)
  }
}

/// The restart button's engine waits for a pass of its own through the watcher.
extension UpdateWatcher: PendingApplying {}
