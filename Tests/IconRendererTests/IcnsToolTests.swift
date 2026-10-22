import CoreGraphics
import Foundation
import Support
import Synchronization
import Testing
@testable import IconRenderer

/// Stands in for `iconutil`: records requests and, for `-c iconset`, writes the given PNGs into the `-o` folder.
final class FakeIconutil: ProcessRunning {
  private let requests = Mutex<[ProcessRequest]>([])
  let iconsetImages: [String: Int]
  let exitCode: Int32
  let timedOut: Bool

  init(iconsetImages: [String: Int] = [:], exitCode: Int32 = 0, timedOut: Bool = false) {
    self.iconsetImages = iconsetImages
    self.exitCode = exitCode
    self.timedOut = timedOut
  }

  var recorded: [ProcessRequest] { requests.withLock { $0 } }

  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    requests.withLock { $0.append(request) }
    if exitCode == 0, !timedOut, request.arguments.first == "-c", request.arguments.dropFirst().first == "iconset",
       let out = request.arguments.last {
      let dir = URL(fileURLWithPath: out, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      for (name, side) in iconsetImages {
        let shade = side % 251
        try BitmapIO.pngData(TestImages.solid(r: shade, g: 0, b: 0, side: side))
          .write(to: dir.appendingPathComponent(name))
      }
    }
    return ProcessResult(exitCode: exitCode, stdout: Data(), stderr: Data("boom".utf8), timedOut: timedOut)
  }
}

func makeIconTempDir(_ name: String = #function) throws -> URL {
  let safe = name.filter { $0.isLetter || $0.isNumber }
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("cmacc-icon-\(safe)-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return TempDirs.register(url)
}

/// Every directory made by `makeTempDir` in this test process; all are removed by one `atexit` handler (S12).
enum TempDirs {
  private static let dirs = Mutex<[URL]>([])
  private static let cleanupInstalled: Void = { atexit { TempDirs.removeAll() } }()

  static func register(_ url: URL) -> URL {
    _ = cleanupInstalled
    dirs.withLock { $0.append(url) }
    return url
  }

  static func removeAll() {
    for url in dirs.withLock({ $0 }) {
      chmod(url.path, 0o700)
      try? FileManager.default.removeItem(at: url)
    }
  }
}

@Suite struct IcnsToolUnitTests {
  /// Every entry `writeIcns` must write, with its pixel size.
  static let writtenEntries: [(name: String, pixels: Int)] = [
    ("icon_16x16@2x.png", 32), ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
  ]

  /// The icns types `iconutil` stores those eight entries under (16@2x, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x).
  static let writtenTypes: Set<String> = ["ic11", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]

  @Test func extractRunsIconutilWithArgumentArrayAndPicks1024() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let fake = FakeIconutil(iconsetImages: [
      "icon_16x16.png": 16, "icon_512x512.png": 512, "icon_512x512@2x.png": 1024, "icon_256x256@2x.png": 512,
    ])
    let icns = work.appendingPathComponent("in.icns")
    let image = try await IcnsTool(runner: fake).extractLargest(from: icns, workDir: work)
    #expect(image.width == 1024)

    let request = try #require(fake.recorded.first)
    #expect(fake.recorded.count == 1)
    #expect(request.executable.path == "/usr/bin/iconutil")
    #expect(request.arguments == ["-c", "iconset", icns.path, "-o", work.appendingPathComponent("x.iconset").path])
    #expect(request.timeout > .zero)
  }

  @Test func extractFallsBackToTheLargestImage() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let fake = FakeIconutil(iconsetImages: ["icon_128x128.png": 128, "icon_256x256.png": 256, "icon_32x32.png": 32])
    let image = try await IcnsTool(runner: fake).extractLargest(from: work.appendingPathComponent("a.icns"), workDir: work)
    #expect(image.width == 256)
  }

  @Test func extractFailsWhenIconutilFails() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let tool = IcnsTool(runner: FakeIconutil(exitCode: 1))
    await #expect(throws: IcnsToolError.iconutilFailed(exitCode: 1, stderr: "boom")) {
      _ = try await tool.extractLargest(from: work.appendingPathComponent("a.icns"), workDir: work)
    }
  }

  @Test func extractFailsOnTimeout() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let tool = IcnsTool(runner: FakeIconutil(timedOut: true))
    await #expect(throws: IcnsToolError.timedOut) {
      _ = try await tool.extractLargest(from: work.appendingPathComponent("a.icns"), workDir: work)
    }
  }

  @Test func extractFailsWhenTheIconsetIsEmpty() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let tool = IcnsTool(runner: FakeIconutil(iconsetImages: [:]))
    await #expect(throws: IcnsToolError.noImages) {
      _ = try await tool.extractLargest(from: work.appendingPathComponent("a.icns"), workDir: work)
    }
  }

  /// The 1× 16 and 32 pt entries (`icon_16x16.png`, `icon_32x32.png`) are never written: with them macOS 26+ puts a
  /// `CFBundleIconFile` icon on the grey legacy platter at ≤ 32 pt 1×.
  @Test func writeBuildsTheEightEntryIconsetWithoutThe1xSmallImages() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let fake = FakeIconutil()
    let destination = work.appendingPathComponent("out/electron.icns")
    // The fake does not produce the .icns, so the final move reports the missing output.
    await #expect(throws: IcnsToolError.outputMissing) {
      try await IcnsTool(runner: fake).writeIcns(from: TestImages.gradient(), to: destination, workDir: work)
    }
    let request = try #require(fake.recorded.first)
    let iconset = work.appendingPathComponent("out.iconset")
    #expect(request.arguments.prefix(4) == ["-c", "icns", iconset.path, "-o"])
    let names = try FileManager.default.contentsOfDirectory(atPath: iconset.path).sorted()
    #expect(names == Self.writtenEntries.map(\.name).sorted())
    #expect(IcnsTool.iconsetEntries.map(\.name) == Self.writtenEntries.map(\.name))
    #expect(!names.contains("icon_16x16.png") && !names.contains("icon_32x32.png"))
    for entry in Self.writtenEntries {
      let image = try BitmapIO.load(iconset.appendingPathComponent(entry.name))
      #expect(image.width == entry.pixels && image.height == entry.pixels, "\(entry.name)")
    }
  }
}

/// Uses the real `/usr/bin/iconutil`, only inside fresh temp directories.
@Suite struct IcnsToolRoundTripTests {
  let tool = IcnsTool(runner: SystemProcessRunner())

  @Test func writeThenExtractRoundTripsA1024Image() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = try TestImages.gradient()
    let icns = work.appendingPathComponent("round.icns")
    try await tool.writeIcns(from: source, to: icns, workDir: work.appendingPathComponent("write"))
    #expect(FileManager.default.fileExists(atPath: icns.path))

    let extractDir = work.appendingPathComponent("extract")
    let extracted = try await tool.extractLargest(from: icns, workDir: extractDir)
    #expect(extracted.width == 1024 && extracted.height == 1024)

    let pngs = try FileManager.default.contentsOfDirectory(atPath: extractDir.appendingPathComponent("x.iconset").path)
      .filter { $0.hasSuffix(".png") }
    #expect(pngs.count == 8)
    #expect(Set(pngs) == Set(IcnsToolUnitTests.writtenEntries.map(\.name)))

    let (a, b) = (try PixelBuffer(source), try PixelBuffer(extracted))
    for (x, y) in [(0, 0), (512, 512), (1000, 20), (100, 900)] {
      #expect(a.pixel(x: x, y: y).isClose(to: b.pixel(x: x, y: y), tolerance: 2), "(\(x), \(y))")
    }
  }

  /// The file `iconutil -c icns` produced holds exactly the eight retina and large types: no `ic04`/`ic05` (1× 16 and
  /// 32 pt PNG) nor the older `is32`/`il32`/`s8mk`/`l8mk`. Metadata entries (`info`, `TOC `, `icnV`) are ignored.
  @Test func writtenIcnsHoldsOnlyTheEightRetinaAndLargeTypes() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let icns = work.appendingPathComponent("types.icns")
    try await tool.writeIcns(from: TestImages.gradient(), to: icns, workDir: work.appendingPathComponent("write"))
    let all = try IcnsFile.entryTypes(of: Data(contentsOf: icns))
    let images = all.filter { !IcnsFile.metadataTypes.contains($0) }
    #expect(images.count == 8, "\(all)")
    #expect(Set(images) == IcnsToolUnitTests.writtenTypes, "\(all)")
    #expect(Set(all).isDisjoint(with: ["ic04", "ic05", "is32", "il32", "s8mk", "l8mk"]), "\(all)")
  }

  @Test func badgeIcnsWritesNo1xSmallEntries() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("source.icns")
    try await tool.writeIcns(from: TestImages.gradient(), to: source, workDir: work.appendingPathComponent("w0"))
    let destination = work.appendingPathComponent("dest/electron.icns")
    try await tool.badgeIcns(source: source, destination: destination, style: .standard(label: "2nd"),
                             workDir: work.appendingPathComponent("w1"))
    let images = try IcnsFile.imageTypes(of: Data(contentsOf: destination))
    #expect(images.count == 8 && Set(images) == IcnsToolUnitTests.writtenTypes, "\(images)")
  }

  @Test func badgeIcnsChangesOnlyThePillArea() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("source.icns")
    try await tool.writeIcns(from: TestImages.gradient(), to: source, workDir: work.appendingPathComponent("w0"))
    let destination = work.appendingPathComponent("dest/electron.icns")
    let style = BadgeStyle.standard(label: "2nd")
    try await tool.badgeIcns(source: source, destination: destination, style: style, workDir: work.appendingPathComponent("w1"))

    let before = try PixelBuffer(await tool.extractLargest(from: source, workDir: work.appendingPathComponent("e0")))
    let after = try PixelBuffer(await tool.extractLargest(from: destination, workDir: work.appendingPathComponent("e1")))
    // Stroke half-width + shadow blur + shadow offset around the pill.
    let pill = try BadgeCompositor.layout(style: style).pill
    let allowed = pill.insetBy(dx: -48, dy: -48)
    var changed = 0, outside = 0
    for y in 0..<1024 {
      for x in 0..<1024 where !before.pixel(x: x, y: y).isClose(to: after.pixel(x: x, y: y), tolerance: 2) {
        changed += 1
        if !allowed.contains(CGPoint(x: x, y: y)) { outside += 1 }
      }
    }
    #expect(changed > Int(pill.width * pill.height * 0.8))
    #expect(outside == 0)
  }
}

/// Reads the real Claude icon (read-only) and writes `badge-real-2nd.png`. Run with `CMACC_INTEGRATION=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CMACC_INTEGRATION"] == "1"))
struct IcnsToolIntegrationTests {
  static let claudeIcns = URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources/electron.icns")

  @Test func badgesTheRealClaudeIcon() async throws {
    let work = try makeIconTempDir()
    defer { try? FileManager.default.removeItem(at: work) }
    let tool = IcnsTool(runner: SystemProcessRunner())
    let base = try await tool.extractLargest(from: Self.claudeIcns, workDir: work.appendingPathComponent("extract"))
    #expect(base.width == 1024)
    let badged = try BadgeCompositor.compose(base: base, style: .standard(label: "2nd"))
    let url = try writeIconArtifact(badged, name: "badge-real-2nd.png")
    #expect(try BitmapIO.load(url).width == 1024)

    let icns = work.appendingPathComponent("out/electron.icns")
    try await tool.badgeIcns(source: Self.claudeIcns, destination: icns, style: .standard(label: "2nd"),
                             workDir: work.appendingPathComponent("badge"))
    #expect(FileManager.default.fileExists(atPath: icns.path))
  }

  /// R1 on the real icon (the registered Assets.car icon, read-only): every label fits at the standard size with no
  /// opaque badge pixel outside the icon body.
  @Test(arguments: ["2nd", "mv2", "5x", "Работа", "5x акк", "WWWWWW"])
  func realIconBadgeStaysInsideTheShape(label: String) throws {
    let app = URL(fileURLWithPath: "/Applications/Claude.app")
    let base = try #require(AppIconSource.rendered(appURL: app, pixels: 1024))
    let fit = try BadgeCompositor.fit(base: base, style: .standard(label: label))
    #expect(fit.scale == 1, "\(label) needed a retry")
    #expect(try BadgeCompositorTests.badgePixelsOutsideTheBody(layer: fit.layer, base: base) == 0)
  }
}
