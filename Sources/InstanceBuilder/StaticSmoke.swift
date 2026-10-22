import CryptoKit
import Foundation
import IconRenderer
import Support

/// File-level checks of a staged clone against its source (never launches or registers anything).
/// `allowCustomIcon` (only `cmacc instance verify`): a clone built before the badge moved into `electron.icns` carries
/// it as a Finder custom icon, so `Icon\r` in the bundle root together with its `com.apple.FinderInfo` is tolerated
/// there; builds since never have it.
public struct StaticSmoke: Sendable {
  private let runner: ProcessRunning

  public init(runner: ProcessRunning) {
    self.runner = runner
  }

  public func run(app: URL, source: URL, spec: CloneSpec, allowCustomIcon: Bool = false) async throws -> [SmokeCheck] {
    try await run(app: app, reference: SourceFacts.read(from: source, runner: runner), spec: spec,
                  allowCustomIcon: allowCustomIcon)
  }

  /// Same checks against facts read from the source earlier (the pipeline never re-reads the live source here).
  public func run(
    app: URL, reference: SourceFacts, spec: CloneSpec, allowCustomIcon: Bool = false
  ) async throws -> [SmokeCheck] {
    let info = (try? PlistPatcher.decode(Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")))) ?? [:]
    let customIcon = allowCustomIcon && CustomIconCheck.inspect(app).present
    var checks = infoChecks(info, spec: spec)
    checks += launcherChecks(app: app, spec: spec)
    checks.append(try await VendorFrameworksCheck(runner: runner).run(app: app, reference: reference))
    checks.append(customIcon ? .skipped("no-finder-info", Self.customIconReason) : try await finderInfoCheck(app: app))
    checks += leftoverChecks(app: app, customIcon: customIcon)
    checks.append(helpersCheck(app: app, reference: reference))
    checks.append(asarCheck(info, reference))
    checks.append(icnsCheck(app: app, reference: reference, spec: spec))
    checks.append(icnsSmallEntriesCheck(app: app, spec: spec))
    return checks
  }

  static let customIconReason = "custom icon of an installed clone"

  private func infoChecks(_ info: [String: Any], spec: CloneSpec) -> [SmokeCheck] {
    let id = info["CFBundleIdentifier"] as? String ?? "missing"
    let display = info["CFBundleDisplayName"] as? String ?? "missing"
    let name = info["CFBundleName"] as? String ?? "missing"
    let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    let docTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    let docNames = docTypes.map { $0["CFBundleTypeName"] as? String ?? "?" }
    let docsOK = docTypes.allSatisfy {
      PlistPatcher.allowedDocumentTypes.contains($0["CFBundleTypeName"] as? String ?? "")
        && $0["LSHandlerRank"] as? String == "Alternate"
    }
    return [
      SmokeCheck("info-id", id == spec.bundleId, id),
      SmokeCheck("display-name", display == spec.displayName, display),
      SmokeCheck("bundle-name-claude", name == "Claude", name),
      iconNameCheck(info["CFBundleIconName"], badged: spec.badge != nil),
      SmokeCheck("url-types-claude-only", schemes.contains("claude") && schemes.allSatisfy { $0 == "claude" },
                 schemes.isEmpty ? "no URL schemes" : schemes.joined(separator: ",")),
      SmokeCheck("doc-types-allowed", docsOK, docNames.joined(separator: ",")),
    ]
  }

  /// Badged: no `CFBundleIconName`, so macOS shows the clone's own `electron.icns`. Unbadged: the name stays, so macOS
  /// shows the vendor's new-format Assets.car icon (no grey legacy platter).
  private func iconNameCheck(_ name: Any?, badged: Bool) -> SmokeCheck {
    let detail = name.map { "\($0)" } ?? "absent"
    return badged ? SmokeCheck("no-icon-name", name == nil, detail) : SmokeCheck("icon-name-kept", name != nil, detail)
  }

  private func launcherChecks(app: URL, spec: CloneSpec) -> [SmokeCheck] {
    let macOS = app.appendingPathComponent("Contents/MacOS")
    let head = (try? FileHandle(forReadingFrom: macOS.appendingPathComponent("Claude")))
      .flatMap { handle in defer { try? handle.close() }; return try? handle.read(upToCount: 4) } ?? Data()
    let real = macOS.appendingPathComponent(LauncherConfigFile.realExecutable)
    let realPresent = FileManager.default.isExecutableFile(atPath: real.path)
    let configURL = app.appendingPathComponent("Contents/Resources/\(LauncherConfigFile.fileName)")
    let config = (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(LauncherConfigFile.self, from: $0) }
    let configOK = config?.matches(spec) ?? false
    return [
      SmokeCheck("launcher-is-macho", Self.isMachO(head), head.map { String(format: "%02x", $0) }.joined()),
      SmokeCheck("claude-real-present", realPresent, realPresent ? "executable" : "missing"),
      SmokeCheck("launcher-config-valid", configOK, config == nil ? "missing or undecodable" : (configOK ? "matches spec" : "mismatch")),
    ]
  }

  private func finderInfoCheck(app: URL) async throws -> SmokeCheck {
    let result = try await runner.runTool(BuilderTool.xattr, ["-l", app.path], timeout: BuilderTool.shortTimeout)
    let present = result.stdoutText.contains("com.apple.FinderInfo")
    return SmokeCheck("no-finder-info", !present, present ? "com.apple.FinderInfo present" : "none")
  }

  private func leftoverChecks(app: URL, customIcon: Bool) -> [SmokeCheck] {
    [("no-icon-r", "Icon\r"), ("no-provisionprofile", "Contents/embedded.provisionprofile"),
     ("no-codesources-ticket", "Contents/CodeResources")].map { name, path in
      if customIcon, name == "no-icon-r" { return .skipped(name, Self.customIconReason) }
      let exists = FileManager.default.fileExists(atPath: app.appendingPathComponent(path).path)
      return SmokeCheck(name, !exists, exists ? "present" : "absent")
    }
  }

  /// Every nested `*.app` in `Contents/Frameworks` and `Contents/Helpers` keeps the source's bundle id.
  private func helpersCheck(app: URL, reference: SourceFacts) -> SmokeCheck {
    let sourceIds = reference.helperIds
    let cloneIds = Self.nestedAppIds(in: app)
    let equal = !sourceIds.isEmpty && sourceIds == cloneIds
    return SmokeCheck("helpers-untouched", equal, equal ? "\(cloneIds.count) helper ids unchanged" : "helper ids differ")
  }

  private func asarCheck(_ info: [String: Any], _ reference: SourceFacts) -> SmokeCheck {
    let key = SourceFacts.asarKey
    let original = SourceFacts.decode(reference.asarIntegrity)
    let equal = NSDictionary(dictionary: [key: info[key] ?? "none"]).isEqual(to: [key: original ?? "none"])
    return SmokeCheck("asar-integrity-unchanged", equal && info[key] != nil, equal ? "unchanged" : "differs")
  }

  /// A badged clone's `electron.icns` differs from the source's (the badge was baked in before signing, R1).
  private func icnsCheck(app: URL, reference: SourceFacts, spec: CloneSpec) -> SmokeCheck {
    guard spec.badge != nil else { return .skipped("icns-badged", "no badge requested") }
    let clone = Self.sha256(of: app.appendingPathComponent(SourceFacts.icnsPath))
    let badged = clone != nil && clone != reference.icnsSHA256
    return SmokeCheck("icns-badged", badged, badged ? "differs from source" : "identical to source or missing")
  }

  /// A badged clone's `electron.icns` has no 1× 16/32 pt image (`IcnsFile.smallOneXTypes`): with one, macOS 26+ draws
  /// the clone on the grey legacy platter at ≤ 32 pt 1× (`IcnsTool.iconsetEntries`). Flags clones built before that
  /// rule, whose `electron.icns` still has `ic04`/`ic05`. Without a badge the vendor's file stays and is not judged.
  private func icnsSmallEntriesCheck(app: URL, spec: CloneSpec) -> SmokeCheck {
    let name = "icns-no-1x-small"
    guard spec.badge != nil else { return .skipped(name, "no badge requested") }
    guard let data = try? Data(contentsOf: app.appendingPathComponent(SourceFacts.icnsPath), options: .mappedIfSafe),
          let images = try? IcnsFile.imageTypes(of: data)
    else { return SmokeCheck(name, false, "missing or not an icns file") }
    let small = images.filter { IcnsFile.smallOneXTypes.contains($0) }
    return SmokeCheck(name, small.isEmpty, small.isEmpty
      ? "\(images.count) images, none 1x 16/32 pt" : "1x small entries: \(small.joined(separator: ","))")
  }

  static func isMachO(_ head: Data) -> Bool {
    let bytes = Array(head.prefix(4))
    guard bytes.count == 4 else { return false }
    let thin: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
    let fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE]
    return bytes == thin || bytes == fat
  }

  static func nestedAppIds(in app: URL) -> [String: String] {
    var ids: [String: String] = [:]
    for folder in ["Contents/Frameworks", "Contents/Helpers"] {
      let dir = app.appendingPathComponent(folder)
      let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
      for name in names where name.hasSuffix(".app") {
        let plist = dir.appendingPathComponent(name).appendingPathComponent("Contents/Info.plist")
        let id = (try? PlistPatcher.decode(Data(contentsOf: plist)))?["CFBundleIdentifier"] as? String
        ids["\(folder)/\(name)"] = id ?? "missing"
      }
    }
    return ids
  }

  static func sha256(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
