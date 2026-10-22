import CoreGraphics
import Foundation
import IconRenderer
import Support

/// The `badge` step: bakes the badge into the clone's `Contents/Resources/electron.icns` before signing (R1), so the
/// badge is sealed with the bundle and stays inside the icon shape (no grey plate on macOS 26+, no Finder custom
/// icon). `Assets.car` is never touched: it also holds images Claude loads at runtime (`ClaudeSpark`, `Noise`,
/// `CameraCursor`); the clone drops `CFBundleIconName` instead (`PlistPatcher`), so macOS shows `electron.icns`.
/// That file is written by `IcnsTool.writeIcns` without the 1× 16/32 pt entries, which would bring the grey legacy
/// platter back at small 1× sizes.
///
/// Base image: the registered icon of the official source app (`NSWorkspace`, the Assets.car icon), only when the
/// source lies in `officialAppsRoot` and outside staging (G4). Any other source (a Claude ClaudeMultiAcc downloaded)
/// takes the registered icon of `<officialAppsRoot>/Claude.app` when that is a real directory outside staging, so every
/// clone keeps the official icon. Otherwise, or when that yields nothing ≥ 512 px, the largest image of the source's
/// `electron.icns`. The pipeline reads it with `baseImage` before `recheck-source` and never queries the icon of a
/// staged bundle. All intermediate files live in `workDir` (same volume as the clone).
public struct BadgeStep: Sendable {
  static let canvas = 1024
  static let minimumPixels = 512
  private let runner: ProcessRunning
  private let iconProvider: any AppIconProviding
  private let staging: StagingArea
  private let officialAppsRoot: URL

  public init(
    runner: ProcessRunning, iconProvider: any AppIconProviding, staging: StagingArea,
    officialAppsRoot: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)
  ) {
    self.runner = runner
    self.iconProvider = iconProvider
    self.staging = staging
    self.officialAppsRoot = officialAppsRoot
  }

  /// Composites the badge onto `base` (from `baseImage`) and replaces the clone's `electron.icns` with it.
  /// Throws `BadgeError` before anything is written when the label is invalid or the badge cannot fit the icon.
  public func apply(app: URL, base: CGImage, label: String, workDir: URL) async throws {
    let badged = try BadgeCompositor.compose(base: base, style: BadgeStyle.standard(label: label))
    let icns = app.appendingPathComponent(SourceFacts.icnsPath)
    try await IcnsTool(runner: runner).writeIcns(from: badged, to: icns, workDir: workDir.appendingPathComponent("write"))
  }

  /// The base image and a detail line naming it (see the type comment); reads only the source.
  public func baseImage(source: URL, workDir: URL) async throws -> (CGImage, String) {
    if isOfficialSource(source) {
      if let icon = renderedIcon(source) { return (icon, "base=workspace-icon \(icon.width)px") }
    } else if let official = installedOfficialApp(), let icon = renderedIcon(official) {
      return (icon, "base=workspace-icon (official) \(icon.width)px")
    }
    let icns = source.appendingPathComponent(SourceFacts.icnsPath)
    let image = try await IcnsTool(runner: runner).extractLargest(from: icns, workDir: workDir.appendingPathComponent("extract"))
    return (image, "base=electron.icns \(image.width)px")
  }

  private func renderedIcon(_ app: URL) -> CGImage? {
    iconProvider.renderedIcon(appURL: app, pixels: Self.canvas, minimumPixels: Self.minimumPixels)
  }

  /// `<officialAppsRoot>/Claude.app` when it is a real directory (not a symlink) outside staging.
  private func installedOfficialApp() -> URL? {
    let app = officialAppsRoot.appendingPathComponent("Claude.app", isDirectory: true)
    guard ClaudeSourceStore.isRealDirectory(app), !staging.contains(app) else { return nil }
    return app
  }

  /// Symlinks are resolved first, so a link in the Applications folder pointing into staging is not official.
  private func isOfficialSource(_ source: URL) -> Bool {
    let root = StagingArea.resolvedPath(officialAppsRoot) + "/"
    return StagingArea.resolvedPath(source).hasPrefix(root) && !staging.contains(source)
  }
}
