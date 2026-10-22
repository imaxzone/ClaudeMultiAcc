import CoreGraphics
import Foundation
import IconRenderer
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// Records which apps were asked for their icon and answers with a fixed image (or nil).
final class FakeIconProvider: AppIconProviding {
  private let calls = Mutex<[String]>([])
  let side: Int?

  init(side: Int?) { self.side = side }

  var requested: [String] { calls.withLock { $0 } }

  func renderedIcon(appURL: URL, pixels: Int, minimumPixels: Int) -> CGImage? {
    calls.withLock { $0.append(appURL.path) }
    guard let side, side >= minimumPixels else { return nil }
    return solidImage(side: pixels)
  }
}

func solidImage(side: Int) -> CGImage? {
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else { return nil }
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: side, height: side))
  return context.makeImage()
}

/// Stands in for iconutil: `-c iconset` writes one 1024 px PNG, `-c icns` writes a marker file.
func fakeIconutil() -> ScriptedRunner {
  ScriptedRunner { request in
    let args = request.arguments
    guard args.first == "-c", let out = args.last else { return .ok() }
    if args[1] == "iconset" {
      let dir = URL(fileURLWithPath: out, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      if let image = solidImage(side: 1024) {
        try BitmapIO.pngData(image).write(to: dir.appendingPathComponent("icon_512x512@2x.png"))
      }
    } else {
      try Data(fakeBadgedIcns.utf8).write(to: URL(fileURLWithPath: out))
    }
    return .ok()
  }
}

/// What `fakeIconutil` writes for `-c icns`: a minimal icns with the eight types `IcnsTool` writes, so a fake build
/// passes `StaticSmoke`'s `icns-no-1x-small`. All its bytes are ASCII, so it round-trips through `String`.
let fakeBadgedIcns = String(decoding: TestIcns.badged, as: UTF8.self)

@Suite struct BadgeStepTests {
  private func setUp(_ root: URL) throws -> (paths: Paths, apps: URL, clone: URL) {
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"))
    let apps = root.appendingPathComponent("Applications", isDirectory: true)
    try MiniBundle.makeSource(in: apps)
    let clone = try MiniBundle.makeSource(in: root.appendingPathComponent("data/staging/x-20260101-000000.noindex"))
    return (paths, apps, clone)
  }

  private func work(_ clone: URL) -> URL { clone.deletingLastPathComponent().appendingPathComponent("work") }

  @Test func usesTheWorkspaceIconOfTheOfficialSourceAndWritesElectronIcns() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, apps, clone) = try setUp(root)
    let provider = FakeIconProvider(side: 1024)
    let runner = fakeIconutil()
    let step = BadgeStep(runner: runner, iconProvider: provider, staging: StagingArea(paths: paths), officialAppsRoot: apps)
    let source = apps.appendingPathComponent("Claude.app")
    let (base, detail) = try await step.baseImage(source: source, workDir: work(clone))
    #expect(detail == "base=workspace-icon 1024px")
    #expect(provider.requested == [source.path])
    try await step.apply(app: clone, base: base, label: "T", workDir: work(clone))
    #expect(runner.commandLines.map { Array($0.prefix(3)) } == [["iconutil", "-c", "icns"]])
    #expect(try Data(contentsOf: clone.appendingPathComponent("Contents/Resources/electron.icns")) == Data(fakeBadgedIcns.utf8))
    #expect(Data(fakeBadgedIcns.utf8) == TestIcns.badged)
    #expect(runner.recorded.allSatisfy { $0.arguments.last?.hasPrefix(work(clone).path) == true })
  }

  @Test func fallsBackToElectronIcnsWhenTheWorkspaceIconIsTooSmall() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, apps, clone) = try setUp(root)
    let provider = FakeIconProvider(side: 256)
    let runner = fakeIconutil()
    let step = BadgeStep(runner: runner, iconProvider: provider, staging: StagingArea(paths: paths), officialAppsRoot: apps)
    let source = apps.appendingPathComponent("Claude.app")
    let (base, detail) = try await step.baseImage(source: source, workDir: work(clone))
    #expect(detail == "base=electron.icns 1024px" && base.width == 1024)
    #expect(provider.requested.count == 1)
    let extract = try #require(runner.commandLines.first)
    #expect(extract == ["iconutil", "-c", "iconset", source.path + "/Contents/Resources/electron.icns", "-o",
                        work(clone).path + "/extract/x.iconset"])
  }

  @Test func neverQueriesSourcesOutsideApplicationsOrInsideStaging() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, apps, clone) = try setUp(root)
    let provider = FakeIconProvider(side: 1024)
    let outside = try MiniBundle.makeSource(in: root.appendingPathComponent("elsewhere"))
    for source in [outside, clone] {
      let step = BadgeStep(runner: fakeIconutil(), iconProvider: provider, staging: StagingArea(paths: paths),
                           officialAppsRoot: source == clone ? root : apps)
      let (_, detail) = try await step.baseImage(source: source, workDir: work(clone))
      #expect(detail.hasPrefix("base=electron.icns"))
    }
    #expect(provider.requested.isEmpty)
  }

  @Test func symlinkIntoStagingIsNotOfficial() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, apps, clone) = try setUp(root)
    let link = apps.appendingPathComponent("Staged Link.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: clone)
    let provider = FakeIconProvider(side: 1024)
    let step = BadgeStep(runner: fakeIconutil(), iconProvider: provider, staging: StagingArea(paths: paths), officialAppsRoot: apps)
    let (_, detail) = try await step.baseImage(source: link, workDir: work(clone))
    #expect(detail.hasPrefix("base=electron.icns"))
    #expect(provider.requested.isEmpty)
  }

  @Test func invalidLabelThrowsBeforeWritingAnything() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let (paths, apps, clone) = try setUp(root)
    let runner = fakeIconutil()
    let step = BadgeStep(runner: runner, iconProvider: FakeIconProvider(side: 1024), staging: StagingArea(paths: paths),
                         officialAppsRoot: apps)
    let base = try #require(solidImage(side: 1024))
    await #expect(throws: BadgeError.labelTooLong(7)) {
      try await step.apply(app: clone, base: base, label: "TOOLONG", workDir: work(clone))
    }
    #expect(runner.recorded.isEmpty)
    #expect(try Data(contentsOf: clone.appendingPathComponent("Contents/Resources/electron.icns")) == Data("icns-original".utf8))
  }
}
