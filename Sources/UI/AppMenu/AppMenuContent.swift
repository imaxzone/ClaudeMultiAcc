import Foundation
import InstanceBuilder
import Support

/// Where a tile's icon comes from.
public enum AppTileIconSource: Equatable, Sendable {
  /// The official app: the icon LaunchServices shows is the right one.
  case workspace(appPath: String)
  /// A clone: its own `Contents/Resources/<CFBundleIconFile>.icns` (LaunchServices would show the grey-framed one).
  case bundleIcns(appPath: String)
  case none
}

/// One app tile of the menu grid.
public struct AppTile: Equatable, Sendable, Identifiable {
  public let slug: String
  /// «Claude mv2» — as in the Dock and Finder.
  public let name: String
  /// «mv2» — the badge, or the name without «Claude » (the banner lists these).
  public let shortName: String
  public let icon: AppTileIconSource
  public let appPath: String?
  public let isOfficial: Bool
  /// The official version this clone can be updated to; nil when it is current, unknown, or a legacy clone.
  public let updateTo: String?

  public var id: String { slug }

  /// «Claude mv2, есть обновление до 3.1700.0».
  public var accessibilityLabel: String { AppMenuStrings.tileLabel(name: name, updateTo: updateTo) }
}

/// «Есть версия 3.1700.0 · для 2nd и mv2 · [Обновить 2]», shown only while at least one clone is behind.
public struct AppMenuBanner: Equatable, Sendable {
  public let version: String
  /// Slugs of the clones behind, in grid order.
  public let slugs: [String]
  public let shortNames: [String]

  public var count: Int { slugs.count }
  public var title: String { AppMenuStrings.bannerTitle(version: version) }
  public var subtitle: String { AppMenuStrings.bannerSubtitle(names: shortNames) }
  public var buttonTitle: String { AppMenuStrings.updateButton(count: count) }
  public var accessibilityLabel: String { "\(title) \(subtitle)" }
}

/// Everything the grid shows, derived from the instance list and installed versions only.
public struct AppMenuContent: Equatable, Sendable {
  public let banner: AppMenuBanner?
  public let tiles: [AppTile]

  public init(banner: AppMenuBanner?, tiles: [AppTile]) {
    self.banner = banner
    self.tiles = tiles
  }

  /// A clone is behind: the status item shows its red dot.
  public var hasUpdates: Bool { banner != nil }

  public static let empty = AppMenuContent(banner: nil, tiles: [])
}

public enum AppMenuContentBuilder {
  /// The official app first (only the first official entry), then clones in `instances.json` order; CLI-only
  /// accounts have no app and are not shown. A clone is behind when `cmacc` built it and its installed version is
  /// older than `officialVersion` (legacy clones are rebuilt by hand and never offer the update).
  public static func build(
    instances: [Instance], officialVersion: String?, installedVersion: (Instance) -> String?
  ) -> AppMenuContent {
    let official = instances.first { $0.kind == .official }
    let apps = (official.map { [$0] } ?? []) + instances.filter { $0.kind == .clone }
    let target = officialVersion.flatMap { $0.isEmpty ? nil : $0 }
    let tiles = apps.map { tile($0, updateTo: updateTarget($0, official: target, installed: installedVersion)) }
    let behind = tiles.filter { $0.updateTo != nil }
    let banner = target.flatMap { version in
      behind.isEmpty
        ? nil : AppMenuBanner(version: version, slugs: behind.map(\.slug), shortNames: behind.map(\.shortName))
    }
    return AppMenuContent(banner: banner, tiles: tiles)
  }

  static let builtByCmacc = "cmacc"

  private static func updateTarget(
    _ instance: Instance, official: String?, installed: (Instance) -> String?
  ) -> String? {
    guard instance.kind == .clone, instance.builtBy == builtByCmacc, let official,
          let version = installed(instance), VersionCompare.isNewer(official, than: version)
    else { return nil }
    return official
  }

  private static func tile(_ instance: Instance, updateTo: String?) -> AppTile {
    let path = instance.appPath.flatMap { $0.isEmpty ? nil : $0 }
    let icon: AppTileIconSource = path.map { instance.kind == .official ? .workspace(appPath: $0) : .bundleIcns(appPath: $0) }
      ?? .none
    return AppTile(
      slug: instance.slug.raw, name: instance.name, shortName: shortName(instance), icon: icon, appPath: path,
      isOfficial: instance.kind == .official, updateTo: updateTo)
  }

  static func shortName(_ instance: Instance) -> String {
    if let badge = instance.badge?.trimmingCharacters(in: .whitespaces), !badge.isEmpty { return badge }
    let prefix = "Claude "
    guard instance.name.hasPrefix(prefix), instance.name.count > prefix.count else { return instance.name }
    return String(instance.name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
  }
}
