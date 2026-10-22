import Foundation
import InstanceBuilder
import Support

/// `cmacc instance new`: the CLI mirror of the "Новый экземпляр…" sheet. `--dry-validate` only validates and
/// prints the derived spec; `--staging-only` builds in staging; `--install` also installs and requires `--yes`.
struct NewInstanceCommand {
  static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

  func run(_ options: InstanceOptions) async throws -> Int32 {
    let staging = options.flags.contains("--staging-only")
    let install = options.flags.contains("--install")
    guard let name = options.values["--name"], staging != install else {
      Console.err(InstanceCommand.usageText)
      return ExitCode.usage
    }
    let paths = Paths.live()
    let request = NewInstanceRequest.derive(
      name: name, slug: options.values["--slug"], badge: options.values["--badge"],
      emails: (options.lists["--email"] ?? []).joined(separator: ","))
    let existing: [Instance]
    do {
      existing = try await InstanceStore(paths: paths).load()
    } catch {
      Console.err("error: \(NewInstanceError.storeCorrupt(paths.instancesFile.path))")
      return ExitCode.failure
    }
    let errors = request.validate(against: existing, applicationsDir: Self.applications, home: paths.home)
    guard errors.isEmpty else {
      errors.forEach { Console.err("error: \($0)") }
      return ExitCode.failure
    }
    if options.flags.contains("--dry-validate") {
      Console.out(Self.describe(request, home: paths.home))
      return ExitCode.success
    }
    if install, !options.flags.contains("--yes") {
      Console.err("--install creates \(request.target(applicationsDir: Self.applications).path) and registers it; pass --yes to confirm")
      return ExitCode.failure
    }
    return try await build(request, options: options, paths: paths, install: install)
  }

  private func build(_ request: NewInstanceRequest, options: InstanceOptions, paths: Paths, install: Bool) async throws -> Int32 {
    try paths.ensureDataDirs()
    let runner = SystemProcessRunner()
    let permanent = await SigningIdentityCheck(paths: paths, runner: runner).permanentIdentity()
    let keychain = options.values["--keychain"].map { URL(fileURLWithPath: $0) }
    let explicit = try options.values["--identity"].map { try SigningIdentity.parse($0, keychain: keychain) }
    let identity: SigningIdentity
    if install {
      do {
        identity = try InstallNewInstance.identity(explicit: explicit, permanent: permanent)
      } catch let error as InstallError {
        Console.err("error: \(error)")
        return ExitCode.usage
      }
    } else {
      identity = explicit ?? permanent ?? .adhoc
    }
    let pipeline = InstanceBuildPipeline(
      paths: paths, runner: runner, launcherBinary: InstanceCommand.launcherURL(options), clock: SystemClock())
    let report = try await pipeline.build(
      spec: request.spec(home: paths.home), source: InstanceCommand.defaultSource(paths), identity: identity,
      intent: install ? .install : .stagingOnly)
    Console.out(InstanceCommand.summary(report))
    guard report.verified else { return ExitCode.failure }
    guard install else {
      Console.out(report.stagedPath)
      return ExitCode.success
    }
    let installer = InstallNewInstance(
      applicationsDir: Self.applications, store: InstanceStore(paths: paths),
      registrar: Registrar(runner: runner, staging: StagingArea(paths: paths)), running: RunningCheck(runner: runner))
    let instance = try await installer.install(
      staged: URL(fileURLWithPath: report.stagedPath, isDirectory: true), request: request, report: report)
    Console.out("installed \(instance.appPath ?? "?") as \(instance.slug.raw)")
    return ExitCode.success
  }

  static func describe(_ request: NewInstanceRequest, home: URL) -> String {
    let spec = request.spec(home: home)
    return [
      "OK", "name:     \(spec.displayName)", "slug:     \(request.slug)", "badge:    \(request.badge ?? "-")",
      "bundleId: \(spec.bundleId)", "profile:  \(spec.profileDir.path)",
      "target:   \(request.target(applicationsDir: applications).path)",
      "emails:   \(request.emails.isEmpty ? "-" : request.emails.joined(separator: ", "))",
    ].joined(separator: "\n")
  }
}
