import Foundation
import InstanceBuilder
import Support
import UI

/// `cmacc ui strings`: where each module's string tables were found and which languages they have, then a sample
/// string of each module in English and Russian, through the same lookup the app uses. Fails (exit 1) when a module's
/// resource bundle is missing or lacks a language: a quick check of an assembled `ClaudeMultiAcc.app`.
enum UIStringsCheck {
  static let bundles = ["ClaudeMultiAcc_Support", "ClaudeMultiAcc_InstanceBuilder", "ClaudeMultiAcc_UI"]

  /// The report lines and whether every table has every language.
  static func report() -> (lines: [String], complete: Bool) {
    var lines: [String] = []
    var complete = true
    for name in bundles {
      let bundle = ResourceBundles.find(name, anchor: Anchor.self)
      let languages = LocalizedTable(bundle: bundle).availableLanguages
      complete = complete && languages == Localization.languages
      lines.append("\(name): \(bundle?.bundleURL.path ?? "not found") [\(languages.joined(separator: ", "))]")
    }
    lines.append("system language: \(Localization.system)")
    for language in Localization.languages {
      Localization.$pinned.withValue(language) { lines += samples().map { "\(language): \($0)" } }
    }
    return (lines, complete)
  }

  /// One string per module: Support's field check, the builder's path refusal, the menu row and a delete option with
  /// its locale-formatted size.
  private static func samples() -> [String] {
    let delete = DeleteDialogText(
      name: "Claude Work", app: URL(fileURLWithPath: "/Applications/Claude Work.app"), appOnlyBytes: 632_000_000,
      profileBytes: 11_968_000_000, hasOldCopies: false, profileReusable: false)
    return [
      InstanceDraftProblem.nameTooLong(45).message,
      ClonePathRefusal.changed(name: "Claude Work", path: "~/Applications/Claude Work.app").userMessage,
      AppMenuStrings.launchAtLogin,
      delete.everything.title,
    ]
  }

  private final class Anchor {}
}
