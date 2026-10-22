import Foundation

/// Finds a module's SwiftPM resource bundle (`ClaudeMultiAcc_<Module>.bundle`) without the generated `Bundle.module`,
/// which looks only beside the main executable (missing `cmacc` in `Contents/Helpers`) and stops the process when
/// nothing is there. Places, in order:
/// - `Contents/Resources` of the app (`scripts/bundle-app.sh` copies the bundles there);
/// - `Contents/Resources` of the bundle holding `anchor` (a test bundle);
/// - beside a bare executable (`swift build` products);
/// - `../Resources` from the real executable (`cmacc` in `Contents/Helpers`, also through a symlink);
/// - beside the bundle holding `anchor` (a test bundle among the products).
public enum ResourceBundles {
  public static func find(_ name: String, anchor: AnyClass) -> Bundle? {
    let main = Bundle.main
    let holder = Bundle(for: anchor)
    let places = candidates(
      mainResources: main.resourceURL, mainBundle: main.bundleURL, executable: main.executableURL,
      holderResources: holder.resourceURL, holderBundle: holder.bundleURL)
    let file = name + ".bundle"
    for directory in places {
      if let bundle = Bundle(url: directory.appendingPathComponent(file, isDirectory: true)) { return bundle }
    }
    AppLog.logger("l10n").error("Resource bundle \(file, privacy: .public) not found: strings show their keys")
    return nil
  }

  /// The folders searched, in order and without repeats.
  static func candidates(
    mainResources: URL?, mainBundle: URL, executable: URL?, holderResources: URL?, holderBundle: URL
  ) -> [URL] {
    let besideExecutable = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
    let list = [
      mainResources, holderResources, mainBundle,
      besideExecutable?.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true),
      holderBundle.deletingLastPathComponent(),
    ]
    var seen: Set<String> = []
    return list.compactMap { $0?.standardizedFileURL }.filter { seen.insert($0.path).inserted }
  }
}
