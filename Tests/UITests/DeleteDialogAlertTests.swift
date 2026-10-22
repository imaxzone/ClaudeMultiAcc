import AppKit
import Foundation
import InstanceBuilder
import Support
import Testing
@testable import UI

/// What the live alert's presenter saw: whether the sizes came in while it held the main thread.
@MainActor
private final class ModalWitness {
  var sizedWhileModal = false
  var presented = 0
  var answered = false

  /// Blocks like `runModal()`: only what the run loop itself runs (as in a modal session) gets through.
  func spinModalLoop(upTo seconds: TimeInterval, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done(), Date() < deadline {
      _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.01))
    }
  }
}

/// The real `NSAlert` of «Удалить «Claude mv2»?», never shown on screen. Snapshots go to
/// `ArtifactsDir.url/delete-dialog/`.
@MainActor
@Suite(.russian) struct DeleteDialogAlertTests {
  /// Calculator's icon stands in for the clone's (never ask for the icon of a real installed clone).
  private static let icon = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
  private static let target = RemovalTarget(
    slug: slug("mv2"), name: "Claude mv2", bundleId: "com.imaxzone.claude.mv2",
    app: URL(fileURLWithPath: "/Applications/Claude mv2.app", isDirectory: true),
    profileDir: URL(fileURLWithPath: "/nonexistent/ClaudeProfiles/mv2", isDirectory: true),
    backups: [URL(fileURLWithPath: "/nonexistent/backup/Claude mv2.app.20261001-120000")], stagingBuilds: [],
    profileReusable: true)

  static var outputDir: URL { ArtifactsDir.url.appendingPathComponent("delete-dialog", isDirectory: true) }

  /// The alert as it opens (sizes «…») or once both sizes are in with «Всё» chosen.
  private static func alert(sized: Bool) -> NSAlert {
    let model = DeleteDialogModel(target: target)
    let alert = AlertDeleteDialogs.makeAlert(for: model, icon: icon)
    if sized {
      model.appOnlyBytes = 632_000_000
      model.profileBytes = 11_968_000_000
      model.choice = .everything
    }
    alert.layout()
    return alert
  }

  @Test(arguments: ["pending", "sized"])
  func alertSnapshots(state: String) throws {
    try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
    for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
      let data = try SnapshotRenderer.png(window: Self.alert(sized: state == "sized").window, appearance: appearance,
                                          scale: 2)
      try data.write(to: Self.outputDir.appendingPathComponent("delete-\(state)-\(look)@2x.png"))
      let rep = try #require(NSBitmapImageRep(data: data))
      #expect(rep.pixelsWide >= Int(DeleteDialogView.width) * 2)
      #expect(rep.pixelsHigh > 300 * 2)
    }
  }

  /// The layout made while the sizes are «…» already has room for the real ones: the window never jumps.
  @Test func sizesArrivingDoNotResizeTheAlert() throws {
    let pending = Self.alert(sized: false)
    #expect(pending.window.frame.size == Self.alert(sized: true).window.frame.size)
    let accessory = try #require(pending.accessoryView)
    #expect(accessory.frame.width == DeleteDialogView.width && accessory.frame.height > 150)
  }

  /// «Удалить» is the rightmost button, red and without Return; «Отмена» answers Escape.
  @Test func deleteIsRedAndOnlyAClickAway() throws {
    let alert = Self.alert(sized: false)
    #expect(alert.messageText == "Удалить «Claude mv2»?")
    #expect(alert.informativeText
      == "Если приложение открыто, оно закроется. Всё удалённое попадёт в Корзину — до её очистки можно вернуть.")
    #expect(alert.buttons.map(\.title) == ["Удалить", "Отмена"])
    let delete = try #require(alert.buttons.first)
    #expect(delete.hasDestructiveAction && delete.keyEquivalent.isEmpty)
    #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
  }

  /// `runModal()` blocks the main thread; the sizes, measured off it, must still reach the open alert. A modal loop
  /// entered from inside a main-actor job never runs other main-actor work, so the alert must not be.
  @Test func theOpenAlertGetsItsSizesWhileModal() async throws {
    let witness = ModalWitness()
    let model = DeleteDialogModel(target: Self.target)
    let dialogs = AlertDeleteDialogs(
      present: { _ in
        witness.presented += 1
        witness.spinModalLoop(upTo: 3) { model.appOnlyBytes != nil }
        witness.sizedWhileModal = model.appOnlyBytes != nil
        return .alertFirstButtonReturn
      },
      icon: { _ in Self.icon })
    Task { model.appOnlyBytes = await FakeRemover().appOnlySize(of: Self.target) }
    let asking = Task {
      let answer = await dialogs.ask(model)
      witness.answered = true
      return answer
    }
    // Bounded, so a presenter that never runs fails the test instead of hanging it.
    for _ in 0..<200 where !witness.answered {
      try await Task.sleep(for: .milliseconds(25))
    }
    try #require(witness.answered)
    #expect(witness.presented == 1 && witness.sizedWhileModal)
    #expect(await asking.value == .appOnly)
  }

  @Test func problemsAreOneAlertWithEveryLine() async {
    var shown: [NSAlert] = []
    let dialogs = AlertDeleteDialogs(
      present: { shown.append($0); return .alertFirstButtonReturn }, icon: { _ in Self.icon })
    await dialogs.showProblems(title: "«Claude mv2» удалён не полностью", lines: ["Первая.", "Вторая."])
    #expect(shown.count == 1)
    #expect(shown.first?.messageText == "«Claude mv2» удалён не полностью")
    #expect(shown.first?.informativeText == "Первая.\n\nВторая.")
    #expect(shown.first?.buttons.map(\.title) == ["ОК"])
  }
}
