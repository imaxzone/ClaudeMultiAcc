import AppKit
import InstanceBuilder

/// Reads the installed version of an app (read-only).
public protocol AppVersionReading: Sendable {
  func version(appPath: String) -> String?
}

/// `CFBundleShortVersionString` from `<app>/Contents/Info.plist`.
public struct InstalledAppVersions: AppVersionReading {
  public init() {}

  public func version(appPath: String) -> String? {
    AppVersion.read(URL(fileURLWithPath: appPath, isDirectory: true))
  }
}

/// Supplies the tile icons.
@MainActor
public protocol AppIconLoading: AnyObject {
  func icon(for source: AppTileIconSource) -> NSImage?
}

/// Clone icons come from the bundle's own `Contents/Resources/<CFBundleIconFile>.icns`, never from
/// `NSWorkspace.icon(forFile:)` (on macOS 26 that is the grey-framed version of a badged clone icon); the official
/// icon comes from LaunchServices. Cached per file and modification date, so a rebuilt clone shows its new icon.
@MainActor
public final class BundleIconLoader: AppIconLoading {
  private struct Entry {
    let stamp: Date?
    let image: NSImage
  }

  private var cache: [String: Entry] = [:]

  public init() {}

  public func icon(for source: AppTileIconSource) -> NSImage? {
    switch source {
    case .none:
      return nil
    case .workspace(let appPath):
      let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
      guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
      return cached(key: "ws:" + appPath, stamp: Self.modified(plist)) { NSWorkspace.shared.icon(forFile: appPath) }
    case .bundleIcns(let appPath):
      guard let icns = Self.icnsURL(appPath: appPath) else { return nil }
      return cached(key: icns.path, stamp: Self.modified(icns)) { NSImage(contentsOf: icns) }
    }
  }

  private func cached(key: String, stamp: Date?, load: () -> NSImage?) -> NSImage? {
    if let entry = cache[key], entry.stamp == stamp { return entry.image }
    guard let image = load() else {
      cache[key] = nil
      return nil
    }
    cache[key] = Entry(stamp: stamp, image: image)
    return image
  }

  /// `<app>/Contents/Resources/<CFBundleIconFile>[.icns]`, when the plist names one and the file exists.
  nonisolated static func icnsURL(appPath: String) -> URL? {
    let app = URL(fileURLWithPath: appPath, isDirectory: true)
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let raw = info["CFBundleIconFile"] as? String
    else { return nil }
    let name = (raw as NSString).lastPathComponent
    guard !name.isEmpty else { return nil }
    let file = name.hasSuffix(".icns") ? name : name + ".icns"
    let url = app.appendingPathComponent("Contents/Resources", isDirectory: true).appendingPathComponent(file)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  private nonisolated static func modified(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }
}
