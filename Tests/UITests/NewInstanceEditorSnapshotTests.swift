import AppKit
import Foundation
import InstanceBuilder
import Support
import SwiftUI
import Testing
@testable import UI

/// Review PNGs of the «Изменить…» / «Добавить» window in its main states, light and dark, in Russian and (`-en`) in
/// English (`ui-editor/` in the artifacts dir). The preview icon is a demo icon written to a temp file, never the
/// installed Claude.
@MainActor
@Suite(.serialized, .russian) struct NewInstanceEditorSnapshotTests {
  private func four() throws -> [Instance] {
    let root = URL(fileURLWithPath: "/tmp/root")
    struct File: Decodable { let instances: [Instance] }
    return try JSONCoding.decoder.decode(File.self, from: Data(try fixtureText("instances-four.json", root: root).utf8)).instances
  }

  private func model(_ mode: InstanceEditorMode, _ knobs: EditorFakeServices.Knobs = .init()) async throws
    -> InstanceEditorViewModel {
    let model = InstanceEditorViewModel(
      mode: mode, services: EditorFakeServices(existing: try four(), knobs), dialogs: EditorFakeDialogs(confirm: true),
      ensureSigning: SigningProbe().closure, refreshDock: DockProbe().closure)
    await model.load()
    return model
  }

  @Test(arguments: Localization.languages)
  func windowStates(language: String) async throws {
    try await Localization.$pinned.withValue(language) { try await renderStates(language) }
  }

  private func renderStates(_ language: String) async throws {
    let previous = BadgePreview.source
    defer { BadgePreview.source = previous }
    let icon = try makeTempDir().appendingPathComponent("demo-icon.png")
    try DemoIcon.pngData(badge: nil).write(to: icon)

    let empty = try await model(.add)
    let typed = try await model(.add)
    typed.name = "claude work"
    var leftoverKnobs = EditorFakeServices.Knobs()
    leftoverKnobs.leftover = true
    let leftover = try await model(.add, leftoverKnobs)
    leftover.name = "Claude mv2"
    var runningKnobs = EditorFakeServices.Knobs()
    runningKnobs.running = true
    let edit = try await model(.edit(slug: "work"), runningKnobs)
    edit.name = "Claude mv2"
    edit.badge = "mv2"
    let closing = try await model(.edit(slug: "work"), runningKnobs)
    closing.name = "Claude mv2"
    closing.badge = "mv2"
    closing.phase = .working(.closing)
    var failing = EditorFakeServices.Knobs()
    failing.verified = false
    let failed = try await model(.add, failing)
    failed.name = "Claude mv2"
    await failed.submit()
    let done = try await model(.edit(slug: "work"), runningKnobs)
    done.name = "Claude mv2"
    done.badge = "mv2"
    await done.submit()
    let reinstall = try await model(.edit(slug: "work"), runningKnobs)
    let reinstalled = try await model(.edit(slug: "work"), runningKnobs)
    await reinstalled.submit()
    let refreshed = try await model(.edit(slug: "work"))
    await refreshed.submit()
    await refreshed.refreshDock()

    let dir = ArtifactsDir.url.appendingPathComponent("ui-editor", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let states = [
      ("add-empty", empty), ("add-taken", typed), ("add-leftover", leftover), ("add-failed", failed),
      ("edit-running", edit), ("edit-closing", closing), ("edit-done", done), ("edit-reinstall", reinstall),
      ("edit-reinstalled", reinstalled), ("edit-dock-refreshed", refreshed),
    ]
    for (name, model) in states {
      // Set right before the synchronous renders: other suites point the preview elsewhere while this one awaits.
      BadgePreview.source = icon
      #expect(BadgePreview.image(label: "") != nil)
      let view = InstanceEditorView(model: model, close: {}).background(Color(nsColor: .windowBackgroundColor))
      let height = SnapshotRenderer.fittingHeight(view, width: InstanceEditorWindowController.width)
      #expect(height > 150 && height < 400, "\(name): \(height)")
      for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let data = try SnapshotRenderer.png(
          view, size: CGSize(width: InstanceEditorWindowController.width, height: height), appearance: appearance, scale: 2)
        let infix = language == "ru" ? "" : "-\(language)"
        try data.write(to: dir.appendingPathComponent("editor-\(name)\(infix)-\(suffix)@2x.png"))
      }
    }
  }

  /// The title follows a rename once it is saved; the model's own `onFinish` still runs. A finished window is replaced
  /// by a fresh one when its mode is asked for again; an unfinished one is reused.
  @Test func theLiveControllerOpensOneWindowPerMode() async throws {
    var models: [InstanceEditorViewModel] = []
    var finished: [String] = []
    let controller = InstanceEditorWindowController { mode in
      let model = InstanceEditorViewModel(
        mode: mode, services: EditorFakeServices(existing: (try? four()) ?? []), dialogs: EditorFakeDialogs(),
        ensureSigning: SigningProbe().closure, refreshDock: DockProbe().closure)
      model.onFinish = { finished.append($0.name) }
      models.append(model)
      return model
    }
    let add = controller.makeWindow(.add)
    #expect(add.title == "Новое приложение")
    let edit = controller.makeWindow(.edit(slug: "work"))
    for _ in 0..<200 where edit.title != "Изменить «Claude Work»" { await Task.yield() }
    #expect(edit.title == "Изменить «Claude Work»")
    let editing = try #require(models.last)
    editing.name = "Claude Job"
    await editing.submit()
    #expect(edit.title == "Изменить «Claude Job»" && finished == ["Claude Job"])
    #expect(controller.window(for: .add) === add)
    let fresh = controller.window(for: .edit(slug: "work"))
    #expect(fresh !== edit && models.count == 3)
    #expect(controller.windowShouldClose(add))
    add.close()
    fresh.close()
  }
}
