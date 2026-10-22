import AppKit
import Support
import SwiftUI
import Testing
@testable import UI

/// `cmacc ui snapshot` output: every surface of the review, light and dark. The PNGs land in
/// `ArtifactsDir.url/ui-task11/` for review; their sizes are checked by `AppMenuSnapshotTests`.
@MainActor
@Suite(.serialized) struct SnapshotCatalogTests {
  static let appearances = ["light", "dark"]

  @Test func rendersEveryListedFileInBothAppearances() async throws {
    let dir = ArtifactsDir.url.appendingPathComponent("ui-task11", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    let urls = try await SnapshotCatalog.renderAll(to: dir, appearances: [.aqua, .darkAqua], scale: 2)
    let expected = Self.appearances.flatMap(AppMenuSnapshotTests.expectedNames)
    #expect(urls.map(\.lastPathComponent) == expected)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)) == Set(expected))
    for url in urls {
      let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
      #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0, "\(url.lastPathComponent)")
    }
  }

  @Test func failedRenderThrows() async throws {
    let dir = try makeTempDir()
    defer {
      chmod(dir.path, 0o700)
      try? FileManager.default.removeItem(at: dir)
    }
    chmod(dir.path, 0o500)
    await #expect(throws: (any Error).self) {
      _ = try await SnapshotCatalog.renderAll(to: dir, appearances: [.aqua], scale: 1)
    }
  }

  @Test func rendererRejectsEmptySize() {
    #expect(throws: SnapshotError.emptySize) {
      try SnapshotRenderer.png(Text("x"), size: .zero, appearance: .aqua, scale: 2)
    }
  }
}

extension CGSize {
  var widthInt: Int { Int(width) }
}
