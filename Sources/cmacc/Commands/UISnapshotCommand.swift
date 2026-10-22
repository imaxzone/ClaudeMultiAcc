import AppKit
import Foundation
import UI

/// `cmacc ui snapshot --out <dir> [--appearance light|dark|both] [--scale 2]`: renders every reviewed surface from
/// demo data offscreen to PNG files (no window is shown and no real account data is read).
/// `cmacc ui strings`: checks that the English and Russian string tables are found (`UIStringsCheck`).
struct UISnapshotCommand: Command {
  static let name = "ui"
  static let summary = "Review shots and string tables: ui snapshot --out <dir> [--appearance …] [--scale 2] | ui strings"
  static let usageText = "Usage: cmacc ui snapshot --out <dir> [--appearance light|dark|both] [--scale 2]\n"
    + "       cmacc ui strings"

  struct Options: Equatable {
    var out: URL
    var appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
    var scale: CGFloat = 2
  }

  func run(_ args: [String]) async throws -> Int32 {
    if args == ["strings"] {
      let report = UIStringsCheck.report()
      report.lines.forEach(Console.out)
      return report.complete ? ExitCode.success : ExitCode.failure
    }
    guard let options = Self.parse(args) else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    await MainActor.run { _ = NSApplication.shared.setActivationPolicy(.prohibited) }
    let urls = try await SnapshotCatalog.renderAll(to: options.out, appearances: options.appearances, scale: options.scale)
    for url in urls { Console.out(url.path) }
    Console.out("\(urls.count) files")
    return ExitCode.success
  }

  static func parse(_ args: [String]) -> Options? {
    guard args.first == "snapshot" else { return nil }
    var out: URL?
    var options = Options(out: URL(fileURLWithPath: "."))
    var rest = ArraySlice(args.dropFirst())
    while let flag = rest.popFirst() {
      guard let value = rest.popFirst() else { return nil }
      switch flag {
      case "--out": out = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
      case "--appearance":
        switch value {
        case "light": options.appearances = [.aqua]
        case "dark": options.appearances = [.darkAqua]
        case "both": options.appearances = [.aqua, .darkAqua]
        default: return nil
        }
      case "--scale":
        guard let scale = Double(value), (1...4).contains(scale) else { return nil }
        options.scale = CGFloat(scale)
      default: return nil
      }
    }
    guard let out else { return nil }
    options.out = out
    return options
  }
}
