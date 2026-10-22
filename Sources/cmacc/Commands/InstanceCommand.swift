import Foundation
import InstanceBuilder
import Support

/// `cmacc instance build|verify|discard|icon|…`: staging builds of clones and their checks.
struct InstanceCommand: Command {
  static let name = "instance"
  static let summary = "Clone builds: instance build|verify|discard|icon|new|rebuild second|rollback second"
  static let usageText = """
    Usage:
      cmacc instance build <slug> --staging-only [--name <display>] [--badge <text>] [--source <app>]
                                  [--identity adhoc|<sha1>] [--keychain <path>] [--launcher <path>] [--json]
      cmacc instance verify <app-path> [--source <app>] [--badge <text>] [--json]
      cmacc instance discard <slug>
      cmacc instance icon <slug>
      cmacc instance new --name <name> [--slug <s>] [--badge <b>] [--email <e>]... --staging-only|--install --yes
                         [--dry-validate] [--identity adhoc|<sha1>] [--keychain <path>] [--launcher <path>]
      cmacc instance rebuild second --check [--keep-staging] [--json]
      cmacc instance rebuild second --apply [--yes]
      cmacc instance rollback second <backup-path> [--yes]

    Clones never modify or re-sign Contents/Frameworks (the vendor helpers reject frameworks with another Team ID);
    --no-neutralize-updater is still accepted and ignored. verify checks this as vendor-frameworks-intact.
    The badge is baked into the clone's electron.icns when it is built (no Finder custom icon); icon is retired and
    only explains this. verify still accepts the Finder custom icon of a clone built before that change: it reports it
    as custom-icon and then runs codesign without --strict.
    """
  static let officialApp = URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)

  /// What a build or verify uses without `--source`: the newest Claude (`ClaudeSourceStore.newest()`, a verified
  /// download only while it is strictly newer than the official app), else the official app's path.
  static func defaultSource(_ paths: Paths, officialApp: URL = InstanceCommand.officialApp) -> URL {
    ClaudeSourceStore(paths: paths, officialApp: officialApp).newest()?.app ?? officialApp
  }

  func run(_ args: [String]) async throws -> Int32 {
    guard let sub = args.first, let options = InstanceOptions.parse(Array(args.dropFirst())) else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    switch sub {
    case "build": return try await build(options)
    case "verify": return try await verify(options)
    case "discard": return try discard(options)
    case "icon": return try await IconCommand().run(options)
    case "new": return try await NewInstanceCommand().run(options)
    case "rebuild": return try await RebuildCommand().run(options)
    case "rollback": return try await RollbackCommand().run(options)
    default:
      Console.err(Self.usageText)
      return ExitCode.usage
    }
  }

  private func build(_ options: InstanceOptions) async throws -> Int32 {
    guard options.flags.contains("--staging-only") else {
      Console.err("install is not implemented from the CLI; staging only")
      return ExitCode.usage
    }
    guard let rawSlug = options.positional.first, let slug = try? Slug(rawSlug) else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    let paths = Paths.live()
    try paths.ensureDataDirs()
    let settings = try await SettingsStore(file: paths.settingsFile).loadStrict()
    let spec = try await resolveSpec(slug: slug, options: options, paths: paths)
    let identity = try Self.stagingIdentity(options, builder: settings.builder)
    let runner = SystemProcessRunner()
    let pipeline = InstanceBuildPipeline(
      paths: paths, runner: runner, launcherBinary: Self.launcherURL(options), clock: SystemClock())
    let source = options.values["--source"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? Self.defaultSource(paths)
    let report = try await pipeline.build(spec: spec, source: source, identity: identity, intent: .stagingOnly)
    if options.flags.contains("--json") {
      Console.out(String(decoding: try JSONCoding.encoder.encode(report), as: UTF8.self))
    } else {
      Console.out(Self.summary(report))
    }
    return report.verified ? ExitCode.success : ExitCode.failure
  }

  /// `--identity` (with an optional `--keychain`), else the identity recorded in settings with its dedicated keychain
  /// (`builder.signingKeychainPath`, unless `--keychain` overrides it), else ad hoc.
  static func stagingIdentity(_ options: InstanceOptions, builder: AppSettings.Builder) throws -> SigningIdentity {
    let keychainOption = options.values["--keychain"]
    if let explicit = options.values["--identity"] {
      return try SigningIdentity.parse(explicit, keychain: keychainOption.map { URL(fileURLWithPath: $0) })
    }
    guard let sha1 = builder.signingIdentitySHA1, !sha1.isEmpty else {
      return try SigningIdentity.parse("adhoc", keychain: keychainOption.map { URL(fileURLWithPath: $0) })
    }
    let keychain = keychainOption ?? builder.signingKeychainPath.flatMap { $0.isEmpty ? nil : $0 }
    return try SigningIdentity.parse(sha1, keychain: keychain.map { URL(fileURLWithPath: $0) })
  }

  /// A registered clone builds from `instances.json` (read-only here); any other slug is a new clone.
  private func resolveSpec(slug: Slug, options: InstanceOptions, paths: Paths) async throws -> CloneSpec {
    let instances = try await InstanceStore(paths: paths).load()
    if let instance = instances.first(where: { $0.slug == slug && $0.kind == .clone }) {
      let spec = try CloneSpec.from(instance: instance)
      return spec.with(badge: options.values["--badge"] ?? spec.badge)
    }
    let name = options.values["--name"] ?? "Claude \(slug.raw.prefix(1).uppercased())\(slug.raw.dropFirst())"
    return CloneSpec.newClone(slug: slug, displayName: name, home: paths.home)
      .with(badge: options.values["--badge"])
  }

  private func verify(_ options: InstanceOptions) async throws -> Int32 {
    guard let path = options.positional.first else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    let app = URL(fileURLWithPath: path, isDirectory: true)
    let stored = try CloneSpec.fromStagedApp(app)
    let spec = options.values["--badge"].map { stored.with(badge: $0) } ?? stored
    let source = options.values["--source"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? Self.defaultSource(Paths.live())
    let runner = SystemProcessRunner()
    let vendor = try await runner.run(ProcessRequest(
      executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-d", "--entitlements", "-", "--xml", source.path],
      timeout: .seconds(30)))
    let expected = try EntitlementsFilter.filter(vendor.stdout)
    // A clone built before the badge moved into electron.icns may still carry a Finder custom icon (`Icon\r` +
    // FinderInfo, unsealed by design): tolerated here only, see `CustomIconCheck`.
    let result = try await Verifier(runner: runner)
      .verify(app: app, spec: spec, expectedEntitlements: expected, allowCustomIcon: true)
    let smoke = try await StaticSmoke(runner: runner).run(app: app, source: source, spec: spec, allowCustomIcon: true)
    let checks = result.checks + smoke
    if options.flags.contains("--json") {
      Console.out(String(decoding: try JSONCoding.encoder.encode(checks), as: UTF8.self))
    } else {
      Console.out(checks.map { "\($0.passed ? "PASS" : "FAIL")  \($0.name)  \($0.detail)" }.joined(separator: "\n"))
    }
    return checks.allSatisfy(\.passed) ? ExitCode.success : ExitCode.failure
  }

  private func discard(_ options: InstanceOptions) throws -> Int32 {
    guard let rawSlug = options.positional.first, let slug = try? Slug(rawSlug) else {
      Console.err(Self.usageText)
      return ExitCode.usage
    }
    let removed = try StagingArea(paths: Paths.live()).discard(slug: slug)
    Console.out("removed \(removed)")
    return ExitCode.success
  }

  /// `--launcher`, else `CloneLauncher` next to this executable (`.build/<cfg>/` or `Contents/Helpers/`).
  static func launcherURL(_ options: InstanceOptions) -> URL {
    if let path = options.values["--launcher"] { return URL(fileURLWithPath: path) }
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
      ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return executable.deletingLastPathComponent().appendingPathComponent("CloneLauncher")
  }

  static func summary(_ report: BuildReport) -> String {
    let steps = report.steps.map { "  \($0.ok ? "ok  " : "FAIL") \($0.name) (\($0.ms) ms) \($0.detail)" }
    let failed = (report.verification + report.smoke).filter { !$0.passed }.map { "  FAIL \($0.name): \($0.detail)" }
    let head = "\(report.verified ? "VERIFIED" : "NOT VERIFIED")  \(report.slug)  \(report.bundleId)  \(report.stagedPath)"
    return ([head] + steps + failed + (report.failure.map { ["failure at \($0.step): \($0.message)"] } ?? []))
      .joined(separator: "\n")
  }
}

/// `--flag`, `--key value` and positional arguments.
struct InstanceOptions {
  static let valueKeys: Set<String> = [
    "--name", "--badge", "--source", "--identity", "--keychain", "--launcher", "--slug", "--label",
  ]
  /// Keys that may repeat; every value is kept in order.
  static let listKeys: Set<String> = ["--email"]
  /// `--no-neutralize-updater` is a retired no-op, kept so existing scripts still parse.
  static let flagKeys: Set<String> = [
    "--staging-only", "--no-neutralize-updater", "--json", "--check", "--apply", "--keep-staging", "--yes",
    "--dry-validate", "--install",
  ]
  let positional: [String]
  let values: [String: String]
  let lists: [String: [String]]
  let flags: Set<String>

  static func parse(_ args: [String]) -> InstanceOptions? {
    parse(args, valueKeys: valueKeys, listKeys: listKeys, flagKeys: flagKeys)
  }

  /// Parses with the given key sets (other commands reuse the same rules).
  static func parse(
    _ args: [String], valueKeys: Set<String>, listKeys: Set<String> = [], flagKeys: Set<String>
  ) -> InstanceOptions? {
    var positional: [String] = []
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []
    var index = 0
    while index < args.count {
      let arg = args[index]
      if listKeys.contains(arg) {
        guard hasValue(args, after: index) else { return nil }
        lists[arg, default: []].append(args[index + 1])
        index += 2
        continue
      }
      if valueKeys.contains(arg) {
        guard hasValue(args, after: index) else { return nil }
        values[arg] = args[index + 1]
        index += 2
        continue
      }
      if flagKeys.contains(arg) {
        flags.insert(arg)
      } else if arg.hasPrefix("--") {
        return nil
      } else {
        positional.append(arg)
      }
      index += 1
    }
    return InstanceOptions(positional: positional, values: values, lists: lists, flags: flags)
  }

  /// A value follows and is not itself an option (`--name --install` is a usage error, not the name "--install").
  private static func hasValue(_ args: [String], after index: Int) -> Bool {
    index + 1 < args.count && !args[index + 1].hasPrefix("--")
  }
}
