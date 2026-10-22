import Foundation
import Support
import Testing
@testable import UI

/// The pure model of the new menu: which tiles, in which order, which of them can be updated, and the banner text.
@Suite(.russian) struct AppMenuContentTests {
  static let official = "3.1700.0"

  static func app(
    _ raw: String, _ name: String, kind: InstanceKind = .clone, badge: String? = nil, builtBy: String? = "cmacc",
    path: String? = nil
  ) -> Instance {
    Instance(
      slug: slug(raw), name: name, kind: kind, bundleId: "com.example.\(raw)",
      appPath: path ?? (kind == .cliOnly ? nil : "/Applications/\(name).app"), badge: badge, builtBy: builtBy)
  }

  /// The owner's list: official «main», clones 2nd / 5x / mv2, a CLI-only account in the middle.
  static let instances: [Instance] = [
    app("main", "Claude", kind: .official, builtBy: nil),
    app("second", "Claude 2nd", badge: "2nd"),
    app("alt", "Claude (alt CLI)", kind: .cliOnly, builtBy: nil),
    app("fivex", "Claude 5x акк", badge: "5x"),
    app("mv2", "Claude mv2", badge: "mv2"),
  ]

  static let versions = ["main": official, "second": "3.1623.0", "fivex": official, "mv2": "3.1623.0"]

  static func build(
    _ instances: [Instance] = instances, official: String? = official, versions: [String: String] = versions
  ) -> AppMenuContent {
    AppMenuContentBuilder.build(
      instances: instances, officialVersion: official, installedVersion: { versions[$0.slug.raw] })
  }

  // MARK: Tiles

  @Test func officialFirstThenClonesInListOrderWithoutCliOnlyAccounts() {
    let reordered = [Self.instances[1], Self.instances[2], Self.instances[0], Self.instances[3], Self.instances[4]]
    let content = Self.build(reordered)
    #expect(content.tiles.map(\.slug) == ["main", "second", "fivex", "mv2"])
    #expect(content.tiles.map(\.isOfficial) == [true, false, false, false])
    #expect(content.tiles.map(\.name) == ["Claude", "Claude 2nd", "Claude 5x акк", "Claude mv2"])
  }

  @Test func onlyTheFirstOfficialEntryIsShown() {
    let twice = Self.instances + [Self.app("main2", "Claude", kind: .official, builtBy: nil)]
    #expect(Self.build(twice).tiles.filter(\.isOfficial).map(\.slug) == ["main"])
  }

  @Test func clonesAreShownWithoutAnOfficialEntry() {
    let clones = Self.instances.filter { $0.kind == .clone }
    #expect(Self.build(clones).tiles.map(\.slug) == ["second", "fivex", "mv2"])
  }

  @Test func emptyListHasNoTilesAndNoBanner() {
    let content = Self.build([])
    #expect(content.tiles.isEmpty)
    #expect(content.banner == nil)
    #expect(!content.hasUpdates)
    #expect(content == .empty)
  }

  @Test func shortNamesUseTheBadgeOrTheNameWithoutClaude() {
    let list = [
      Self.app("main", "Claude", kind: .official, builtBy: nil), Self.app("a", "Claude 2nd", badge: "2nd"),
      Self.app("b", "Claude Work"), Self.app("c", "Research"), Self.app("d", "Claude Lab", badge: "  "),
    ]
    #expect(Self.build(list).tiles.map(\.shortName) == ["Claude", "2nd", "Work", "Research", "Lab"])
  }

  @Test func iconSourcesUseTheBundleIcnsForClonesAndTheWorkspaceForTheOfficialApp() {
    let list = Self.instances + [Self.app("ghost", "Claude Ghost", path: "")]
    let tiles = Self.build(list).tiles
    #expect(tiles[0].icon == .workspace(appPath: "/Applications/Claude.app"))
    #expect(tiles[1].icon == .bundleIcns(appPath: "/Applications/Claude 2nd.app"))
    #expect(tiles.last?.icon == AppTileIconSource.none)
    #expect(tiles[1].appPath == "/Applications/Claude 2nd.app")
  }

  // MARK: Updates

  @Test func clonesBehindTheOfficialVersionOfferTheUpdate() {
    let tiles = Self.build().tiles
    #expect(tiles.map(\.updateTo) == [nil, Self.official, nil, Self.official])
  }

  @Test func legacyClonesNeverShowTheUpdateArrow() {
    let list = [
      Self.app("main", "Claude", kind: .official, builtBy: nil),
      Self.app("second", "Claude 2nd", badge: "2nd", builtBy: "legacy-script"),
      Self.app("mv2", "Claude mv2", badge: "mv2", builtBy: nil),
    ]
    let content = Self.build(list)
    #expect(content.tiles.map(\.updateTo) == [nil, nil, nil])
    #expect(content.banner == nil)
  }

  @Test func unknownVersionsNeverOfferAnUpdate() {
    #expect(Self.build(official: nil).tiles.allSatisfy { $0.updateTo == nil })
    #expect(Self.build(official: "").tiles.allSatisfy { $0.updateTo == nil })
    let noClones = Self.build(versions: ["main": Self.official]).tiles
    #expect(noClones.allSatisfy { $0.updateTo == nil })
  }

  @Test func versionsAreComparedNumericallyNotAsText() {
    let newer = Self.build(official: "3.999.0", versions: ["second": "3.1000.0"]).tiles
    #expect(newer.first { $0.slug == "second" }?.updateTo == nil)
    let ahead = Self.build(versions: ["second": "3.1701.0", "fivex": "3.1700", "mv2": "3.1700.1"]).tiles
    #expect(ahead.allSatisfy { $0.updateTo == nil })
  }

  @Test func bannerNamesEveryCloneBehindAndCountsThem() throws {
    let banner = try #require(Self.build().banner)
    #expect(banner.title == "Есть версия 3.1700.0")
    #expect(banner.subtitle == "для 2nd и mv2")
    #expect(banner.buttonTitle == "Обновить 2")
    #expect(banner.count == 2)
    #expect(banner.slugs == ["second", "mv2"])
    #expect(banner.accessibilityLabel == "Есть версия 3.1700.0 для 2nd и mv2")
  }

  @Test func bannerForOneCloneSaysJustUpdate() throws {
    let banner = try #require(Self.build(versions: Self.versions.merging(["mv2": Self.official]) { $1 }).banner)
    #expect(banner.subtitle == "для 2nd")
    #expect(banner.buttonTitle == "Обновить")
    #expect(banner.count == 1)
  }

  @Test func bannerListsThreeOrMoreWithCommasAndAnd() throws {
    let behind = ["second": "1.0", "fivex": "1.0", "mv2": "1.0"]
    let banner = try #require(Self.build(versions: behind).banner)
    #expect(banner.subtitle == "для 2nd, 5x и mv2")
    #expect(banner.buttonTitle == "Обновить 3")
  }

  @Test func noBannerWhenEveryCloneIsCurrent() {
    let current = Self.build(versions: ["main": Self.official, "second": Self.official, "fivex": Self.official,
                                        "mv2": Self.official])
    #expect(current.banner == nil)
    #expect(!current.hasUpdates)
  }

  // MARK: VoiceOver

  @Test func accessibilityLabelsSpeakNameAndUpdate() {
    let labels = Self.build().tiles.map(\.accessibilityLabel)
    #expect(labels == [
      "Claude", "Claude 2nd, есть обновление до 3.1700.0", "Claude 5x акк", "Claude mv2, есть обновление до 3.1700.0",
    ])
  }
}
