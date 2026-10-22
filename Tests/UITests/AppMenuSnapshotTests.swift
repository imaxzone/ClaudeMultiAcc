import AppKit
import Support
import SwiftUI
import Testing
@testable import UI

/// Review shots of the new menu and its status item; the PNGs land in `ArtifactsDir.url/appmenu/`.
@MainActor
@Suite(.serialized, .russian) struct AppMenuSnapshotTests {
  static let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]
  static let statusItems = ["statusitem", "statusitem-update", "statusitem-updating"]
  static let panelStates = ["normal", "update", "focus", "updating", "deleting"]
  /// The panel states shot again in English.
  static let englishPanelStates = ["normal-en", "update-en"]

  /// The new-menu part of `cmacc ui snapshot`, per appearance: the Russian shots, then the English ones.
  static func expectedNames(_ appearance: String) -> [String] {
    statusItems.flatMap { ["\($0)-\(appearance)@1x.png", "\($0)-\(appearance)@2x.png"] }
      + (panelStates + ["actions", "official"] + englishPanelStates + ["actions-en", "official-en"])
        .map { "appmenu-\($0)-\(appearance).png" }
  }

  private static func bitmap(_ url: URL) throws -> NSBitmapImageRep {
    try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
  }

  private static func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
  }

  @Test func rendersEveryShotInBothAppearancesAtTheExpectedSizes() throws {
    let dir = ArtifactsDir.url.appendingPathComponent("appmenu", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (appearance, suffix) in Self.appearances {
      for shot in AppMenuShots.all(scale: 2) {
        try shot.render(appearance).write(to: dir.appendingPathComponent(shot.name(suffix)))
      }
    }
    let expected = Self.appearances.flatMap { Self.expectedNames($0.1) }
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == Set(expected))

    for (_, suffix) in Self.appearances {
      for name in Self.statusItems {
        let one = try Self.bitmap(dir.appendingPathComponent("\(name)-\(suffix)@1x.png"))
        let two = try Self.bitmap(dir.appendingPathComponent("\(name)-\(suffix)@2x.png"))
        #expect((one.pixelsWide, one.pixelsHigh) == (SnapshotCatalog.menuBarStrip.widthInt, 24))
        #expect((two.pixelsWide, two.pixelsHigh) == (SnapshotCatalog.menuBarStrip.widthInt * 2, 48))
      }
      for state in Self.panelStates + Self.englishPanelStates {
        let rep = try Self.bitmap(dir.appendingPathComponent("appmenu-\(state)-\(suffix).png"))
        #expect(rep.pixelsWide == Int(AppMenuStyle.width * 2), "\(state)")
        #expect(rep.pixelsHigh > 400 && rep.pixelsHigh < 1000, "\(state): \(rep.pixelsHigh)")
        // The panel fills its shot: its hairline is in the first and the last pixel row (no empty bands, no clipping).
        let middle = rep.pixelsWide / 2
        #expect(Self.alpha(rep, middle, 0) > 0.2, "\(state): top edge")
        #expect(Self.alpha(rep, middle, rep.pixelsHigh - 1) > 0.2, "\(state): bottom edge")
      }
      for name in AppMenuShots.tileMenus.map(\.0) + AppMenuShots.englishTileMenus.map({ "\($0.0)-en" }) {
        let rep = try Self.bitmap(dir.appendingPathComponent("\(name)-\(suffix).png"))
        #expect(rep.pixelsWide >= Int(AppMenuStyle.width * 2) && rep.pixelsHigh > 400, "\(name)")
      }
    }
  }

  /// The status-item shots differ only by the blue mark in the glyph's gap: none, the dot, or the open spinner ring
  /// (hollow in the middle, blue on its rim).
  @Test func statusItemShotsShowTheDotOnlyWhenUpdating() throws {
    func isBlue(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
      guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
      return color.blueComponent > 0.8 && color.redComponent < 0.3
    }
    for (appearance, _) in Self.appearances {
      let shots = AppMenuShots.all(scale: 2).filter { $0.name("x").hasPrefix("statusitem") && $0.name("x").hasSuffix("@2x.png") }
      #expect(shots.map { $0.name("x") } == Self.statusItems.map { "\($0)-x@2x.png" })
      let reps = try shots.map { try #require(NSBitmapImageRep(data: try $0.render(appearance))) }
      // The glyph slot starts at 24 + 16 pt; the dot's centre in strip pixels (top-left origin) at 2x.
      let x = Int((40 + (24 - StatusGlyph.size.width) / 2 + StatusGlyph.dotCenter.x) * 2)
      let y = Int(((24 - StatusGlyph.size.height) / 2 + StatusGlyph.size.height - StatusGlyph.dotCenter.y) * 2)
      // The ring's bottom, half a line inside its outer edge.
      let rim = y + Int(((StatusGlyph.spinnerDiameter - StatusGlyph.spinnerLineWidth) / 2 * 2).rounded())
      #expect(!isBlue(reps[0], x, y) && !isBlue(reps[0], x, rim), "\(appearance.rawValue): no mark")
      #expect(isBlue(reps[1], x, y), "\(appearance.rawValue): the dot")
      #expect(!isBlue(reps[2], x, y) && isBlue(reps[2], x, rim), "\(appearance.rawValue): the spinner ring")
    }
  }

  @Test func reviewedStatesShowWhatTheirNamesSay() {
    let normal = AppMenuShots.controller(.normal).model
    #expect(normal.content.banner == nil && normal.release == nil && normal.login.isOn)
    let update = AppMenuShots.controller(.update).model
    #expect(update.content.banner?.slugs == ["second", "mv2"] && update.release != nil && !update.login.isOn)
    let focus = AppMenuShots.controller(.focus).model
    #expect(focus.hasKeyboardFocus(.tile("mv2")))
    #expect(focus.login.subtitle == "Разрешите в Системных настройках")
    let updating = AppMenuShots.controller(.updating).model
    #expect(updating.busy == AppMenuBusy(updating: true) && updating.content.banner?.slugs == ["second", "mv2"])
    let deleting = AppMenuShots.controller(.deleting).model
    #expect(deleting.busy == AppMenuBusy(deleting: ["fivex"]) && deleting.content.banner != nil)
  }

  /// The new menu keeps its width and, even with a dozen clones all behind, fits a 900 pt screen.
  @Test func appMenuStaysNarrowAndShortWithManyClones() {
    let clones = (1...12).compactMap { index in
      AppMenuDemo.demoSlug("c\(index)").map {
        Instance(slug: $0, name: "Claude \(index)", kind: .clone, appPath: "/Applications/Claude \(index).app",
                 badge: "\(index)", builtBy: "cmacc")
      }
    }
    let versions = Dictionary(uniqueKeysWithValues: clones.map { ($0.slug.raw, "1.0") })
      .merging(["main": AppMenuDemo.officialVersion]) { $1 }
    let controller = AppMenuDemo.controller(instances: [AppMenuDemo.instances[0]] + clones, versions: versions)
    #expect(controller.model.content.tiles.count == 13)
    #expect(controller.model.content.banner?.buttonTitle == "Обновить 12")
    let host = NSHostingController(rootView: AppMenuSnapshotPanel(model: controller.model, anchors: nil))
    #expect(host.sizeThatFits(in: CGSize(width: 1000, height: 1000)).width == AppMenuStyle.width)
    #expect(AppMenuShots.panelHeight(controller.model) <= 900)
  }

  /// The demo the review shows: official + three clones (two behind), the CLI-only account hidden, a release.
  @Test func appMenuDemoCoversTheReviewedStates() {
    let model = AppMenuDemo.controller().model
    #expect(model.content.tiles.map(\.name) == ["Claude", "Claude 2nd", "Claude 5x акк", "Claude mv2"])
    #expect(model.content.banner?.subtitle == "для 2nd и mv2")
    #expect(model.content.banner?.buttonTitle == "Обновить 2")
    #expect(model.release?.version == "1.4.0")
    #expect(model.icons.count == 4)
    #expect(model.login.state == .off)
  }
}

/// The actions menu in the review is wide enough for every title, in both languages.
@MainActor
@Suite struct AppMenuShotMenuWidthTests {
  @Test(arguments: Localization.languages)
  func actionsMenuIsWideEnoughForTheLongestTitle(language: String) {
    Localization.$pinned.withValue(language) { checkWidths() }
  }

  private func checkWidths() {
    let tiles = AppMenuDemo.controller().model.content.tiles
    for tile in tiles {
      let menu = AppTileMenu.make(for: tile, target: AppTileMenuTarget { _ in })
      let width = AppMenuShots.width(of: menu)
      let font = NSFont.menuFont(ofSize: 13)
      let longest = menu.items.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
      // Image column (16), gap (6), the insets on both sides (2 × 14).
      #expect(width >= longest + 16 + 6 + 2 * MenuSnapshot.horizontalInset, "\(tile.slug): \(width) for \(longest)")
    }
  }
}
