import Foundation
import InstanceBuilder
import os
import Support

/// The two flows behind the window's button.
extension InstanceEditorViewModel {
  /// «Создать»: signing, staging build, confirmation, the leftover profile to the Trash («начать с чистого»), install,
  /// open. A leftover found only now (after the window asked nothing) is kept: the safe answer.
  func create() async {
    let request = services.newRequest(name: name, badge: badge, existing: existing)
    let reusesProfile = services.leftoverProfile(slug: request.slug, existing: existing) != nil
    let startClean = reusesProfile && leftoverSlug == request.slug && leftoverChoice == .startClean
    guard let identity = await prepareSigning() else { return }
    phase = .working(.building)
    guard let report = await verifiedBuild(request, identity: identity) else { return }
    phase = .working(.confirming)
    guard await dialogs.confirmInstall(request: request, report: report) else {
      await discardBuild(slug: request.slug)
      phase = .editing
      return
    }
    phase = .working(.installing)
    guard await clearLeftoverProfile(request, if: startClean) else { return }
    do {
      let staged = URL(fileURLWithPath: report.stagedPath, isDirectory: true)
      let instance = try await services.install(staged: staged, request: request, report: report)
      phase = .working(.opening)
      let opened = await open(instance)
      finish(instance, title: InstanceEditorText.created(instance.name), detail: Self.createdDetail(
        opened: opened, signedIn: reusesProfile && !startClean))
    } catch {
      log.error("install failed: \(String(describing: error), privacy: .public)")
      await discardBuild(slug: request.slug)
      phase = .failed(Self.text(for: error))
    }
  }

  /// «Сохранить» or «Переустановить» (nothing changed): signing, then the edit engine reports its stages; the
  /// outcome's warnings become the detail.
  func save() async {
    guard let original else { return }
    reinstalling = isReinstall
    let change = InstanceChange(slug: original.slug, name: name, badge: badge, reinstall: reinstalling)
    guard let identity = await prepareSigning() else { return }
    phase = .working(.building)
    do {
      let outcome = try await services.edit(change, identity: identity) { [weak self] stage in await self?.show(stage) }
      replaceOriginal(with: outcome.instance)
      let reopened = outcome.reopened ? [InstanceEditorText.reopened(outcome.instance.name)] : []
      let detail = (reopened + outcome.warnings).joined(separator: "\n")
      let title = reinstalling ? InstanceEditorText.reinstalled : InstanceEditorText.saved
      finish(outcome.instance, title: title, detail: detail.isEmpty ? nil : detail)
    } catch {
      log.error("edit failed: \(String(describing: error), privacy: .public)")
      phase = .failed(Self.text(for: error))
      isRunning = await services.isRunning(original)
    }
  }

  static func createdDetail(opened: Bool, signedIn: Bool) -> String {
    InstanceEditorText.createdDetail(opened: opened, signedIn: signedIn)
  }

  /// «Начать с чистого»: the leftover folder goes to the Trash (already gone is fine); false (and `.failed`) when it
  /// cannot.
  private func clearLeftoverProfile(_ request: NewInstanceRequest, if startClean: Bool) async -> Bool {
    guard startClean, services.leftoverProfile(slug: request.slug, existing: existing) != nil else { return true }
    do {
      try await services.trashLeftoverProfile(slug: request.slug, existing: existing)
      return true
    } catch {
      log.error("cannot trash the leftover profile: \(String(describing: error), privacy: .public)")
      await discardBuild(slug: request.slug)
      phase = .failed(InstanceEditorText.leftoverTrashFailed)
      return false
    }
  }

  private func verifiedBuild(_ request: NewInstanceRequest, identity: SigningIdentity) async -> BuildReport? {
    do {
      let report = try await services.build(request, identity: identity)
      guard report.verified else {
        log.error("build not verified at \(report.failure?.step ?? "?", privacy: .public)")
        await discardBuild(slug: request.slug)
        phase = .failed(Self.text(for: EditInstanceError.notVerified(step: report.failure?.step)))
        return nil
      }
      return report
    } catch {
      log.error("build failed: \(String(describing: error), privacy: .public)")
      await discardBuild(slug: request.slug)
      phase = .failed(Self.text(for: error))
      return nil
    }
  }

  private func open(_ instance: Instance) async -> Bool {
    guard let appPath = instance.appPath else { return false }
    do {
      try await services.open(app: URL(fileURLWithPath: appPath, isDirectory: true))
      return true
    } catch {
      log.error("cannot open \(appPath, privacy: .public): \(String(describing: error), privacy: .public)")
      return false
    }
  }

  private func discardBuild(slug: String) async {
    do {
      try await services.discard(slug: slug)
    } catch {
      log.error("discard \(slug, privacy: .public) failed: \(String(describing: error), privacy: .public)")
    }
  }
}
