import Foundation
import Testing
@testable import IconRenderer

/// The app icon's committed files: the Icon Composer source (`assets/AppIcon.icon`), what `scripts/make-app-icon.sh`
/// compiled from it (`assets/AppIcon/`), and the bundle script that ships both under the name `AppIcon`.
@Suite struct AppIconAssetsTests {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  static let source = root.appendingPathComponent("assets/AppIcon.icon", isDirectory: true)
  static let compiled = root.appendingPathComponent("assets/AppIcon", isDirectory: true)

  struct Document: Decodable {
    struct Group: Decodable {
      struct Layer: Decodable {
        let imageName: String
        let glass: Bool?
        enum CodingKeys: String, CodingKey { case imageName = "image-name", glass }
      }
      let layers: [Layer]
    }
    struct Platforms: Decodable { let squares: [String] }
    let groups: [Group]
    let supportedPlatforms: Platforms
    enum CodingKeys: String, CodingKey { case groups, supportedPlatforms = "supported-platforms" }
  }

  @Test func theIconComposerSourceIsAMacOSGlassIconWithEveryLayerImage() throws {
    let data = try Data(contentsOf: Self.source.appendingPathComponent("icon.json"))
    let document = try JSONDecoder().decode(Document.self, from: data)
    #expect(document.supportedPlatforms.squares.contains("macOS"))
    let layers = document.groups.flatMap(\.layers)
    #expect(layers.map(\.imageName) == ["front.svg", "back.svg"])
    #expect(layers.allSatisfy { $0.glass == true })
    for layer in layers {
      let image = Self.source.appendingPathComponent("Assets/\(layer.imageName)")
      let svg = try String(contentsOf: image, encoding: .utf8)
      #expect(svg.contains(#"viewBox="0 0 1024 1024""#), "\(layer.imageName)")
    }
  }

  @Test func theCompiledIconIsCommitted() throws {
    let car = try FileManager.default.attributesOfItem(atPath: Self.compiled.appendingPathComponent("Assets.car").path)
    #expect((car[.size] as? Int ?? 0) > 100_000)
    // actool's flat fallback for systems without Liquid Glass icons: up to 256 pt @2x (ic13).
    let icns = try Data(contentsOf: Self.compiled.appendingPathComponent("AppIcon.icns"))
    #expect(try IcnsFile.imageTypes(of: icns).contains("ic13"))
  }

  @Test func theAppBundleShipsTheIconAsAppIcon() throws {
    let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/bundle-app.sh"), encoding: .utf8)
    for key in ["CFBundleIconName", "CFBundleIconFile"] {
      #expect(script.contains("<key>\(key)</key>\n  <string>AppIcon</string>"), "\(key)")
    }
    #expect(script.contains(#"for file in Assets.car AppIcon.icns; do"#))
  }
}
