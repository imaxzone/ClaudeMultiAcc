import Foundation
import Support
import Testing
@testable import InstanceBuilder

@Suite(.russian) struct NewInstanceRequestTests {
  private func four(_ root: URL) throws -> [Instance] {
    let text = String(decoding: try fixtureData("instances-four.json"), as: UTF8.self)
      .replacingOccurrences(of: "{{ROOT}}", with: root.path)
    struct File: Decodable { let instances: [Instance] }
    return try JSONCoding.decoder.decode(File.self, from: Data(text.utf8)).instances
  }

  @Test(arguments: [
    ("Work", "work", "Work"), ("Работа", "rabota", "Раб"), ("My Team 2", "my-team-2", "My"), ("Ö", "o", "Ö"),
    ("  Spaced  ", "spaced", "Spa"), ("日本", "ri-ben", "日本"), ("!!!", "", "!!!"), ("Lab", "lab", "Lab"),
    ("Home5", "home5", "Home5"),
  ])
  func derivesSlugAndBadgeFromTheName(name: String, slug: String, badge: String) {
    let request = NewInstanceRequest.derive(name: name)
    #expect(request.slug == slug)
    #expect(request.badge == badge)
    #expect(request.name == name.trimmingCharacters(in: .whitespaces))
  }

  @Test func explicitValuesWinAndEmailsAreParsed() {
    let request = NewInstanceRequest.derive(name: "Work", slug: "job", badge: "J", emails: " a@x.io, ,b@y.org ")
    #expect(request == NewInstanceRequest(name: "Work", slug: "job", badge: "J", emails: ["a@x.io", "b@y.org"]))
    #expect(request.displayName == "Claude Work")
    let spec = request.spec(home: URL(fileURLWithPath: "/Users/u", isDirectory: true))
    #expect(spec.bundleId == "com.imaxzone.claude.job" && spec.displayName == "Claude Work" && spec.badge == "J")
    #expect(spec.profileDir.path == "/Users/u/Library/Application Support/ClaudeProfiles/job")
  }

  @Test func validationTableAgainstFourInstances() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let apps = root.appendingPathComponent("Applications", isDirectory: true)
    try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude Taken.app"), withIntermediateDirectories: true)
    let existing = try four(root)
    func errors(_ r: NewInstanceRequest) -> [NewInstanceError] {
      r.validate(against: existing, applicationsDir: apps, home: root)
    }
    #expect(errors(.derive(name: "Personal", emails: "me@example.com")).isEmpty)
    #expect(errors(.derive(name: "Main")) == [.duplicateSlug("main")])
    // P7: a taken slug is one message, not three (its bundle id and profile follow from it).
    #expect(errors(.derive(name: "Work")) == [
      .duplicateSlug("work"), .duplicateAppPath(apps.appendingPathComponent("Claude Work.app").path),
    ])
    #expect(errors(.derive(name: "Fresh", slug: "Bad_Slug")) == [.badSlug("Bad_Slug")])
    #expect(errors(.derive(name: "Fresh", badge: "TOOLONG")) == [.badBadge("TOOLONG")])
    #expect(errors(.derive(name: "Fresh", emails: "ok@example.com, nope")) == [.badEmail("nope")])
    #expect(errors(.derive(name: "Taken")) == [.targetExists(apps.appendingPathComponent("Claude Taken.app").path)])
    #expect(errors(NewInstanceRequest(name: "", slug: "x", badge: "x", emails: [])) == [.emptyName])
    #expect(errors(.derive(name: String(repeating: "n", count: 41), slug: "long")) == [.nameTooLong(41)])
    #expect(errors(.derive(name: "a/b", slug: "ab")) == [.invalidName("a/b")])
    #expect(errors(NewInstanceRequest(name: "Fresh", slug: "fresh", badge: "", emails: [])) == [.badBadge("")])
  }

  @Test func duplicateProfileDirIsReported() {
    let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)
    let clash = Instance(slug: testSlug("old"), name: "Old", kind: .clone, bundleId: "com.imaxzone.claude.old",
                         profileDir: "/Users/u/Library/Application Support/ClaudeProfiles/fresh")
    let errors = NewInstanceRequest.derive(name: "Fresh").validate(
      against: [clash], applicationsDir: URL(fileURLWithPath: "/nonexistent-apps"), home: home)
    #expect(errors == [.duplicateProfileDir("/Users/u/Library/Application Support/ClaudeProfiles/fresh")])
  }

  @Test func errorsCarryTheirFieldAndARussianMessage() {
    #expect(NewInstanceError.badEmail("x").field == .emails)
    #expect(NewInstanceError.duplicateSlug("main").field == .slug)
    #expect(NewInstanceError.badBadge("").field == .badge)
    #expect(NewInstanceError.emptyName.field == .name)
    #expect(NewInstanceError.duplicateSlug("main").message == "Экземпляр «main» уже есть — выберите другое короткое имя")
    #expect(NewInstanceError.storeCorrupt("/x").field == .general)
  }
}

@Suite(.russian) struct InstallNewInstanceTests {
  struct Fixture {
    let root: URL
    let paths: Paths
    let apps: URL
    let log: EventLog
    let installer: InstallNewInstance
    let builder: FakeCloneBuilder
  }

  private func fixture(
    running: Bool = false, registrar: (@Sendable (Paths, EventLog) -> any AppRegistering)? = nil,
    _ name: String = #function
  ) throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let four = String(decoding: try fixtureData("instances-four.json"), as: UTF8.self)
      .replacingOccurrences(of: "{{ROOT}}", with: root.path)
    try FileManager.default.createDirectory(at: paths.dataDir, withIntermediateDirectories: true)
    try Data(four.utf8).write(to: paths.instancesFile)
    let apps = root.appendingPathComponent("Applications", isDirectory: true)
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    let log = EventLog()
    let installer = InstallNewInstance(
      applicationsDir: apps, store: InstanceStore(paths: paths), registrar: registrar?(paths, log) ?? FakeRegistrar(log: log),
      running: FakeRunningCheck(running: running))
    return Fixture(root: root, paths: paths, apps: apps, log: log, installer: installer,
                   builder: FakeCloneBuilder(paths: paths, log: log))
  }

  private func build(
    _ f: Fixture, _ request: NewInstanceRequest, verified: Bool = true,
    identity: SigningIdentity = .certificate(sha1: testSHA1, keychain: nil)
  ) async throws -> (URL, BuildReport) {
    let builder = FakeCloneBuilder(paths: f.paths, log: f.log, verified: verified)
    let report = try await builder.build(spec: request.spec(home: f.root), source: f.apps, identity: identity, intent: .install)
    return (URL(fileURLWithPath: report.stagedPath, isDirectory: true), report)
  }

  @Test func installsAtTheEndOfTheListAndRegistersOnce() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal", emails: "me@example.com")
    let (staged, report) = try await build(f, request)
    let instance = try await f.installer.install(staged: staged, request: request, report: report)
    let target = f.apps.appendingPathComponent("Claude Personal.app")
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/MacOS/Claude").path))
    #expect(!FileManager.default.fileExists(atPath: staged.path))
    #expect(f.log.all.filter { $0.hasPrefix("register") } == ["register(Claude Personal.app,new)"])
    #expect(f.log.all.last == "register(Claude Personal.app,new)")
    #expect(instance.slug.raw == "personal" && instance.kind == .clone && instance.builtBy == "cmacc")
    #expect(instance.bundleId == "com.imaxzone.claude.personal" && instance.appPath == target.path)
    #expect(instance.emails == ["me@example.com"] && instance.badge == "Per" && instance.name == "Claude Personal")
    #expect(instance.profileDir == f.root.appendingPathComponent("Library/Application Support/ClaudeProfiles/personal").path)
    let stored = try await InstanceStore(paths: f.paths).load()
    #expect(stored.map(\.slug.raw) == ["main", "second", "work", "alt", "personal"])
    #expect(!FileManager.default.fileExists(atPath: try #require(instance.profileDir)))
  }

  /// R1: the badge was baked into `electron.icns` by the build; installing writes no Finder custom icon (`Icon\r`
  /// would be unsealed) and touches nothing after the registration and the store update.
  @Test func installWritesNoFinderCustomIcon() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal")
    let (staged, report) = try await build(f, request)
    let instance = try await f.installer.install(staged: staged, request: request, report: report)
    let target = try #require(instance.appPath.map { URL(fileURLWithPath: $0, isDirectory: true) })
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(CustomIconCheck.iconFile).path))
    #expect(!CustomIconCheck.inspect(target).present)
  }

  /// Ad hoc builds are "только проверка": never installable, even when verified.
  @Test func refusesAnAdhocBuild() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal")
    let (staged, report) = try await build(f, request, identity: .adhoc)
    await #expect(throws: InstallError.adhocBuild) {
      _ = try await f.installer.install(staged: staged, request: request, report: report)
    }
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(!f.log.all.contains { $0.hasPrefix("register") })
  }

  /// `cmacc instance new --install`: an explicit certificate or the permanent identity, never ad hoc.
  @Test func installIdentityNeverFallsBackToAdhoc() throws {
    let permanent = SigningIdentity.certificate(sha1: testSHA1, keychain: nil)
    let explicit = SigningIdentity.certificate(sha1: String(repeating: "CD", count: 20), keychain: nil)
    #expect(try InstallNewInstance.identity(explicit: nil, permanent: permanent) == permanent)
    #expect(try InstallNewInstance.identity(explicit: explicit, permanent: nil) == explicit)
    #expect(throws: InstallError.noPermanentIdentity) { try InstallNewInstance.identity(explicit: nil, permanent: nil) }
    #expect(throws: InstallError.adhocBuild) { try InstallNewInstance.identity(explicit: .adhoc, permanent: permanent) }
    #expect(InstallError.noPermanentIdentity.description.contains(SigningSetup.hint))
    #expect(!InstallError.noPermanentIdentity.userMessage.contains("scripts/"))
  }

  @Test func refusesAnUnverifiedReport() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal")
    let (staged, report) = try await build(f, request, verified: false)
    await #expect(throws: InstallError.notVerified) {
      _ = try await f.installer.install(staged: staged, request: request, report: report)
    }
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(!f.log.all.contains { $0.hasPrefix("register") })
  }

  @Test func refusesAnExistingTargetAndLeavesItAlone() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal")
    let (staged, report) = try await build(f, request)
    let target = f.apps.appendingPathComponent("Claude Personal.app")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    await #expect(throws: InstallError.invalid([.targetExists(target.path)])) {
      _ = try await f.installer.install(staged: staged, request: request, report: report)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    #expect(try await InstanceStore(paths: f.paths).load().count == 4)
  }

  @Test func refusesAReportOfAnotherRequestOrARunningApp() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let (staged, report) = try await build(f, .derive(name: "Personal"))
    await #expect(throws: InstallError.reportMismatch) {
      _ = try await f.installer.install(staged: staged, request: .derive(name: "Other"), report: report)
    }
    let busy = try fixture(running: true, "busy")
    defer { try? FileManager.default.removeItem(at: busy.root) }
    let (staged2, report2) = try await build(busy, .derive(name: "Personal"))
    await #expect(throws: InstallError.running("com.imaxzone.claude.personal")) {
      _ = try await busy.installer.install(staged: staged2, request: .derive(name: "Personal"), report: report2)
    }
  }

  /// A failed registration moves the app back to staging and leaves the list alone (S5).
  @Test func failedRegistrationMovesTheAppBackToStaging() async throws {
    let f = try fixture(registrar: { _, _ in ThrowingRegistrar(corrupt: nil) })
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal")
    let (staged, report) = try await build(f, request)
    await #expect(throws: InstallError.afterMove(step: "register", message: "lsregister failed", restoredTo: staged.path)) {
      _ = try await f.installer.install(staged: staged, request: request, report: report)
    }
    #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/Claude").path))
    #expect(!FileManager.default.fileExists(atPath: f.apps.appendingPathComponent("Claude Personal.app").path))
    #expect(try await InstanceStore(paths: f.paths).load().count == 4)
  }

  /// The list cannot be written after registration: the app goes back to staging too.
  @Test func failedStoreUpdateMovesTheAppBackToStaging() async throws {
    let f = try fixture(registrar: { paths, _ in ThrowingRegistrar(corrupt: paths.instancesFile) })
    defer { try? FileManager.default.removeItem(at: f.root) }
    let request = NewInstanceRequest.derive(name: "Personal")
    let (staged, report) = try await build(f, request)
    do {
      _ = try await f.installer.install(staged: staged, request: request, report: report)
      Issue.record("install must throw")
    } catch let InstallError.afterMove(step, _, restoredTo) {
      #expect(step == "store")
      #expect(restoredTo == staged.path)
    }
    #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/Claude").path))
    #expect(InstallError.afterMove(step: "store", message: "m", restoredTo: "/s/app").description.contains("/s/app"))
    #expect(InstallError.compensationFailed(original: "m", leftAt: "/Applications/x.app").description
      .contains("/Applications/x.app"))
  }
}

/// Fails `register` (no `corrupt`), or corrupts `instances.json` during it so the following store write fails.
struct ThrowingRegistrar: AppRegistering {
  struct Failure: Error, CustomStringConvertible {
    var description: String { "lsregister failed" }
  }

  let corrupt: URL?

  func register(_ app: URL) async throws {
    guard let corrupt else { throw Failure() }
    try Data("{ not json".utf8).write(to: corrupt)
  }

  func unregister(_ app: URL) async throws {}
}
