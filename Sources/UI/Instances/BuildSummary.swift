import Foundation

/// Titles of the build steps (the editor's failure message), in the UI language; an unknown step keeps its id.
enum BuildSummary {
  static func stepTitle(_ id: String) -> String {
    switch id {
    case "preflight": UIText.string("step.preflight")
    case "probe": UIText.string("step.probe")
    case "copy": UIText.string("step.copy")
    case "patch-plist": UIText.string("step.patch-plist")
    case "clean": UIText.string("step.clean")
    case "snapshot-source": UIText.string("step.snapshot-source")
    case "recheck-source": UIText.string("step.recheck-source")
    case "launcher": UIText.string("step.launcher")
    case "badge": UIText.string("step.badge")
    case "entitlements": UIText.string("step.entitlements")
    case "sign": UIText.string("step.sign")
    case "requirement": UIText.string("step.requirement")
    case "verify": UIText.string("step.verify")
    case "smoke": UIText.string("step.smoke")
    default: id
    }
  }
}
