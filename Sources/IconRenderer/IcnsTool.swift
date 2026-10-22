import CoreGraphics
import Foundation
import os
import Support

public enum IcnsToolError: Error, Equatable {
  case iconutilFailed(exitCode: Int32, stderr: String)
  case timedOut
  case noImages
  case outputMissing
}

/// Converts between `.icns` files and images with `/usr/bin/iconutil`, always through `ProcessRunning` (G9).
/// Every intermediate file lives in the caller's `workDir`; the source `.icns` is only read.
public struct IcnsTool: Sendable {
  static let iconutil = URL(fileURLWithPath: "/usr/bin/iconutil")
  static let timeout: Duration = .seconds(60)
  static let preferredEntry = "icon_512x512@2x.png"

  /// The eight iconset entries `writeIcns` writes: 16 and 32 pt at 2× only, 128, 256 and 512 pt at 1× and 2×
  /// (icns `ic11 ic12 ic07 ic13 ic08 ic14 ic09 ic10`).
  ///
  /// Never the 1× `icon_16x16` / `icon_32x32` (`ic04`/`ic05`, formerly `is32`/`il32` with masks): macOS 26+ draws a
  /// legacy `CFBundleIconFile` icon that has them on the grey "legacy icon" platter whenever it is shown at ≤ 32 pt
  /// at 1×, whatever the images hold. Without them the same art is drawn clean at every size and scale (1× small
  /// sizes are scaled down from the 2× images). `StaticSmoke`'s `icns-no-1x-small` flags a clone that has them.
  static let iconsetEntries: [(name: String, pixels: Int)] = [16, 32].map { side in
    ("icon_\(side)x\(side)@2x.png", side * 2)
  } + [128, 256, 512].flatMap { side in
    [("icon_\(side)x\(side).png", side), ("icon_\(side)x\(side)@2x.png", side * 2)]
  }

  private let runner: ProcessRunning
  private let log = AppLog.logger("icons")

  public init(runner: ProcessRunning) {
    self.runner = runner
  }

  /// The 1024 px image of `icns` (`icon_512x512@2x.png`), or the largest image when that entry is missing.
  public func extractLargest(from icns: URL, workDir: URL) async throws -> CGImage {
    let iconset = workDir.appendingPathComponent("x.iconset", isDirectory: true)
    try prepare(workDir: workDir, removing: iconset)
    try await iconutil(["-c", "iconset", icns.path, "-o", iconset.path])
    let names = (try? FileManager.default.contentsOfDirectory(atPath: iconset.path))?
      .filter { $0.hasSuffix(".png") } ?? []
    if names.contains(Self.preferredEntry) {
      return try BitmapIO.load(iconset.appendingPathComponent(Self.preferredEntry))
    }
    let images = try names.map { try BitmapIO.load(iconset.appendingPathComponent($0)) }
    guard let largest = images.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
      throw IcnsToolError.noImages
    }
    return largest
  }

  /// Writes the eight-entry `.icns` (`iconsetEntries`, no 1× 16/32 pt image) rendered from `image` to `icns`,
  /// replacing an existing file.
  public func writeIcns(from image: CGImage, to icns: URL, workDir: URL) async throws {
    let iconset = workDir.appendingPathComponent("out.iconset", isDirectory: true)
    let output = workDir.appendingPathComponent("out.icns")
    try prepare(workDir: workDir, removing: iconset)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for entry in Self.iconsetEntries {
      let scaled = entry.pixels == image.width && entry.pixels == image.height
        ? image : try BitmapIO.resized(image, side: entry.pixels)
      try BitmapIO.pngData(scaled).write(to: iconset.appendingPathComponent(entry.name))
    }
    try await iconutil(["-c", "icns", iconset.path, "-o", output.path])
    try install(output, at: icns)
  }

  /// Reads `source`, composites the badge onto its largest image and writes the badged `.icns` to `destination`
  /// through `writeIcns`, so none of the source's 1× 16/32 pt entries is carried over.
  public func badgeIcns(source: URL, destination: URL, style: BadgeStyle, workDir: URL) async throws {
    let base = try await extractLargest(from: source, workDir: workDir.appendingPathComponent("extract"))
    let badged = try BadgeCompositor.compose(base: base, style: style)
    try await writeIcns(from: badged, to: destination, workDir: workDir.appendingPathComponent("write"))
    log.info("badged icon \(style.label, privacy: .public) written to \(destination.path, privacy: .public)")
  }

  private func prepare(workDir: URL, removing stale: URL) throws {
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: stale.path) { try FileManager.default.removeItem(at: stale) }
  }

  private func iconutil(_ arguments: [String]) async throws {
    let result = try await runner.run(ProcessRequest(executable: Self.iconutil, arguments: arguments, timeout: Self.timeout))
    if result.timedOut {
      log.error("iconutil timed out: \(arguments, privacy: .public)")
      throw IcnsToolError.timedOut
    }
    guard result.exitCode == 0 else {
      let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
      log.error("iconutil failed (\(result.exitCode)): \(stderr, privacy: .public)")
      throw IcnsToolError.iconutilFailed(exitCode: result.exitCode, stderr: stderr)
    }
  }

  /// Moves the finished file into place so a failed conversion never leaves a half-written destination.
  private func install(_ output: URL, at destination: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: output.path) else { throw IcnsToolError.outputMissing }
    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: output)
    } else {
      try fileManager.moveItem(at: output, to: destination)
    }
  }
}
