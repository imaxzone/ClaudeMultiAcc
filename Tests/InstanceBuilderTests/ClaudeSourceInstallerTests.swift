import CryptoKit
import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// A downloaded Claude archive on its way into `ClaudeSourceStore`: size, checksum, unpack, signature, version, lock
/// and the atomic slot rename; and the downloader itself. Nothing touches the network: `ditto` and `codesign` are
/// scripted, the downloader talks to `ClaudeArchiveStubProtocol`.
@Suite struct ClaudeSourceInstallerTests {
  static let version = "3.1623.3"

  /// One bundle the scripted `ditto` unpacks at the top of its destination.
  struct FakeApp: Sendable {
    var name = "Claude.app"
    var version = ClaudeSourceInstallerTests.version
    var bundleId = CloneSpec.vendorBundleId
  }

  struct Fixture {
    let paths: Paths
    let store: ClaudeSourceStore
    let archive: URL
    let release: ClaudeRelease
    var unpacked: URL { store.incomingDir.appendingPathComponent("unpacked", isDirectory: true) }
    var unpackedApp: URL { unpacked.appendingPathComponent("Claude.app", isDirectory: true) }
  }

  /// A few bytes standing in for the archive in `incoming.noindex`, and the release describing them exactly.
  func fixture(_ name: String = #function) throws -> Fixture {
    let root = try makeTempDir(name)
    let paths = Paths(home: root, dataDir: root.appendingPathComponent("data"), logsDir: root.appendingPathComponent("logs"))
    let store = ClaudeSourceStore(paths: paths, officialApp: root.appendingPathComponent("Applications/Claude.app"))
    let bytes = Data("not really a zip: \(name)".utf8)
    let archive = store.incomingDir.appendingPathComponent("Claude.zip")
    try FileManager.default.createDirectory(at: store.incomingDir, withIntermediateDirectories: true)
    try bytes.write(to: archive)
    let release = ClaudeRelease(
      version: Self.version, url: try Self.downloadURL("Claude-abc"), sha256: Self.hex(bytes), size: Int64(bytes.count))
    return Fixture(paths: paths, store: store, archive: archive, release: release)
  }

  static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

  static func downloadURL(_ name: String) throws -> URL {
    try #require(URL(string: "https://downloads.claude.ai/releases/darwin/arm64/\(version)/\(name).zip"))
  }

  /// `ditto` unpacks `apps` (or fails with `dittoExit`); `codesign -dv` reports `team`, `--verify` passes and
  /// `--verify --deep` against Anthropic's requirement exits `deepExit`.
  static func runner(
    _ apps: [FakeApp] = [FakeApp()], dittoExit: Int32 = 0, team: String = "Q6L2SF6YDW", deepExit: Int32 = 0
  ) -> ScriptedRunner {
    ScriptedRunner { request in
      switch request.executable.lastPathComponent {
      case "ditto":
        guard dittoExit == 0, let destination = request.arguments.last else {
          return .fail(dittoExit, stderr: "ditto: Couldn't read PKZip signature")
        }
        for app in apps { try makeApp(URL(fileURLWithPath: destination).appendingPathComponent(app.name), app) }
        return .ok()
      case "codesign":
        if request.arguments.contains("--deep") {
          return deepExit == 0 ? .ok() : .fail(deepExit, stderr: "test-requirement: code failed to satisfy specified code requirement(s)")
        }
        if request.arguments.first == "--verify" { return .ok() }
        return .ok(stderr: "Identifier=\(CloneSpec.vendorBundleId)\nTeamIdentifier=\(team)\n")
      default:
        return .fail(stderr: "unexpected \(request.executable.path)")
      }
    }
  }

  static func makeApp(_ app: URL, _ fake: FakeApp) throws {
    try ClaudeSourceStoreTests.makeClaude(app, version: fake.version, bundleId: fake.bundleId)
    try MiniBundle.write(MiniBundle.machOBytes, app.appendingPathComponent("Contents/MacOS/Claude"), mode: 0o755)
  }

  func installer(
    _ f: Fixture, _ runner: ScriptedRunner, sleep: @escaping @Sendable (Duration) async -> Void = { _ in }
  ) -> ClaudeSourceInstaller {
    ClaudeSourceInstaller(paths: f.paths, store: f.store, runner: runner, sleep: sleep)
  }

  func rootEntries(_ f: Fixture) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: f.store.root.path)) ?? []).sorted()
  }

  func makeOlderDownload(_ f: Fixture) throws {
    try ClaudeSourceStoreTests.makeClaude(f.store.slot(for: "3.1623.1").appendingPathComponent("Claude.app"), version: "3.1623.1")
  }

  // MARK: installer

  @Test func aGoodArchiveIsStoredAndOlderDownloadsPruned() async throws {
    let f = try fixture()
    try makeOlderDownload(f)
    let slot = f.store.slot(for: Self.version)
    try FileManager.default.createDirectory(at: slot.appendingPathComponent("half"), withIntermediateDirectories: true)
    let runner = Self.runner()
    let source = try await installer(f, runner).install(archive: f.archive, release: f.release)

    let app = slot.appendingPathComponent("Claude.app", isDirectory: true)
    #expect(source == ClaudeSource(app: app, version: Self.version, isOfficial: false))
    #expect(f.store.downloaded() == source)
    #expect(rootEntries(f) == ["3.1623.3.noindex", "incoming.noindex"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: slot.path) == ["Claude.app"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.incomingDir.path) == ["Claude.zip"])
    #expect(runner.commandLines == [
      ["ditto", "-x", "-k", f.archive.path, f.unpacked.path],
      ["codesign", "-dv", "--verbose=2", f.unpackedApp.path],
      ["codesign", "--verify", "--strict", f.unpackedApp.path],
      ["codesign", "--verify", "--deep", "--strict", "-R=\(ClaudeSourceInstaller.requirement(team: "Q6L2SF6YDW"))", f.unpackedApp.path],
    ])
    #expect(ClaudeSourceInstaller.requirement(team: "Q6L2SF6YDW") == #"anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#)
    guard case .acquired(let lock) = UpdateLock.acquire(UpdateLock.file(f.paths)) else {
      Issue.record("update.lock is still held")
      return
    }
    lock.release()
  }

  @Test func aWrongSizeOrChecksumStoresNothing() async throws {
    let f = try fixture()
    try makeOlderDownload(f)
    let runner = Self.runner()
    let r = f.release
    let longer = ClaudeRelease(version: r.version, url: r.url, sha256: r.sha256, size: r.size + 1)
    await #expect(throws: ClaudeUpdateFailure.sizeMismatch(expected: r.size + 1, actual: r.size)) {
      try await installer(f, runner).install(archive: f.archive, release: longer)
    }
    let otherSum = ClaudeRelease(version: r.version, url: r.url, sha256: String(repeating: "0", count: 64), size: r.size)
    await #expect(throws: ClaudeUpdateFailure.checksumMismatch) {
      try await installer(f, runner).install(archive: f.archive, release: otherSum)
    }
    #expect(runner.recorded.isEmpty)
    #expect(rootEntries(f) == ["3.1623.1.noindex", "incoming.noindex"])
  }

  @Test func aWrongTeamOrBundleIdIsNotGenuine() async throws {
    let f = try fixture()
    let runners = [
      Self.runner(team: "ABCDE12345"), Self.runner([FakeApp(bundleId: "com.example.claude")]), Self.runner(deepExit: 3),
    ]
    for runner in runners {
      let failure = await #expect(throws: ClaudeUpdateFailure.self) {
        try await installer(f, runner).install(archive: f.archive, release: f.release)
      }
      guard case .notGenuine? = failure else {
        Issue.record("expected notGenuine, got \(String(describing: failure))")
        continue
      }
      #expect(rootEntries(f) == ["incoming.noindex"])
      #expect(!FileManager.default.fileExists(atPath: f.unpacked.path))
    }
  }

  @Test func aVersionOtherThanTheFeedsIsRejected() async throws {
    let f = try fixture()
    await #expect(throws: ClaudeUpdateFailure.versionMismatch(expected: "3.1623.3", found: "3.1623.2")) {
      try await installer(f, Self.runner([FakeApp(version: "3.1623.2")])).install(archive: f.archive, release: f.release)
    }
    #expect(rootEntries(f) == ["incoming.noindex"])
    #expect(!FileManager.default.fileExists(atPath: f.unpacked.path))
  }

  @Test func twoAppsOrNoneInTheArchiveFailToUnpack() async throws {
    let f = try fixture()
    let elsewhere = f.paths.home.appendingPathComponent("elsewhere/Claude.app", isDirectory: true)
    try Self.makeApp(elsewhere, FakeApp())
    let linked = ScriptedRunner { request in
      guard request.executable.lastPathComponent == "ditto", let destination = request.arguments.last else { return .ok() }
      try FileManager.default.createSymbolicLink(
        at: URL(fileURLWithPath: destination).appendingPathComponent("Claude.app"), withDestinationURL: elsewhere)
      return .ok()
    }
    let runners = [
      Self.runner([FakeApp(), FakeApp(name: "Other.app")]), Self.runner([]), Self.runner([FakeApp(name: "Claude 2.app")]),
      Self.runner(dittoExit: 1), linked,
    ]
    for runner in runners {
      let failure = await #expect(throws: ClaudeUpdateFailure.self) {
        try await installer(f, runner).install(archive: f.archive, release: f.release)
      }
      guard case .unpackFailed? = failure else {
        Issue.record("expected unpackFailed, got \(String(describing: failure))")
        continue
      }
      #expect(runner.commandLines.map(\.first) == ["ditto"])
      #expect(rootEntries(f) == ["incoming.noindex"])
      #expect(!FileManager.default.fileExists(atPath: f.unpacked.path))
    }
    #expect(FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("Contents/Info.plist").path))
  }

  @Test func aHeldUpdateLockRetriesThenReportsBusy() async throws {
    let f = try fixture()
    guard case .acquired(let held) = UpdateLock.acquire(UpdateLock.file(f.paths)) else {
      Issue.record("cannot take update.lock")
      return
    }
    defer { held.release() }
    let slept = ClaudeInstallRecorder<Duration>()
    await #expect(throws: ClaudeUpdateFailure.busy) {
      try await installer(f, Self.runner(), sleep: { slept.record($0) }).install(archive: f.archive, release: f.release)
    }
    #expect(slept.all == Array(repeating: ClaudeSourceInstaller.lockRetry, count: ClaudeSourceInstaller.lockAttempts - 1))
    #expect(rootEntries(f) == ["incoming.noindex"])
    #expect(!FileManager.default.fileExists(atPath: f.unpacked.path))
  }

  @Test(.timeLimit(.minutes(1))) func anInterruptedDownloadLeavesNothingInTheStore() async throws {
    let f = try fixture()
    let release = try Self.stubRelease("cut")
    let failure = await #expect(throws: ClaudeUpdateFailure.self) {
      try await Self.stubbedDownloader().download(release, to: f.archive) { _ in }
    }
    guard case .network? = failure else {
      Issue.record("expected network, got \(String(describing: failure))")
      return
    }
    #expect(rootEntries(f) == ["incoming.noindex"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: f.store.incomingDir.path).isEmpty)

    // A half-written archive (a crash mid-write) never gets as far as `ditto`.
    let half = ClaudeArchiveStubProtocol.payload.prefix(100)
    try half.write(to: f.archive)
    let runner = Self.runner()
    await #expect(throws: ClaudeUpdateFailure.sizeMismatch(expected: release.size, actual: 100)) {
      try await installer(f, runner).install(archive: f.archive, release: release)
    }
    #expect(runner.recorded.isEmpty)
    #expect(rootEntries(f) == ["incoming.noindex"])
  }

  // MARK: downloader

  static func stubbedDownloader() -> ClaudeArchiveDownloader {
    let config = ClaudeArchiveDownloader.configuration()
    config.protocolClasses = [ClaudeArchiveStubProtocol.self]
    return ClaudeArchiveDownloader(session: URLSession(configuration: config))
  }

  /// A release served by `ClaudeArchiveStubProtocol` in the given scenario.
  static func stubRelease(_ scenario: String) throws -> ClaudeRelease {
    let payload = ClaudeArchiveStubProtocol.payload
    return ClaudeRelease(version: version, url: try downloadURL(scenario), sha256: hex(payload), size: Int64(payload.count))
  }

  @Test func theDownloaderRefusesARedirectToAnotherHost() async throws {
    let allowed = try Self.downloadURL("Claude-def")
    #expect(ClaudeArchiveDownloader.allowsRedirect(to: allowed))
    let refused = [
      "https://evil.example/releases/darwin/arm64/x.zip", "http://downloads.claude.ai/releases/darwin/arm64/x.zip",
      "https://downloads.claude.ai.evil.example/releases/darwin/x.zip", "https://downloads.claude.ai:8443/releases/darwin/x.zip",
      "https://downloads.claude.ai/releases/darwin/arm64/x.delta", "https://downloads.claude.ai/other/x.zip",
    ]
    for target in refused {
      #expect(!ClaudeArchiveDownloader.allowsRedirect(to: URL(string: target)), "\(target)")
    }

    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let original = try Self.downloadURL("Claude-abc")
    let task = session.downloadTask(with: original) // never resumed: no network
    let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
    let delegate = ClaudeArchiveDownloadDelegate(
      expectedSize: 1, destination: try makeTempDir().appendingPathComponent("x.zip"), progress: { _ in })
    let followed = await delegate.urlSession(
      session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: allowed))
    #expect(followed?.url == allowed)
    #expect(delegate.failure == nil)
    let evil = try #require(URL(string: refused[0]))
    #expect(await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: evil)) == nil)
    #expect(delegate.failure == .untrustedURL(refused[0]))
  }

  @Test(.timeLimit(.minutes(1))) func theDownloaderSavesTheArchiveAndReportsProgress() async throws {
    let file = try makeTempDir().appendingPathComponent("Claude.zip")
    try Data("left over".utf8).write(to: file)
    let progress = ClaudeInstallRecorder<Double>()
    try await Self.stubbedDownloader().download(try Self.stubRelease("whole"), to: file) { progress.record($0) }
    #expect(try Data(contentsOf: file) == ClaudeArchiveStubProtocol.payload)
    #expect(!progress.all.isEmpty)
    #expect(progress.all == progress.all.sorted())
    #expect(progress.all.last == 1)
  }

  @Test(.timeLimit(.minutes(1))) func theDownloaderTurnsHTTPErrorsAndForeignURLsIntoFailures() async throws {
    let file = try makeTempDir().appendingPathComponent("Claude.zip")
    await #expect(throws: ClaudeUpdateFailure.network("HTTP 404")) {
      try await Self.stubbedDownloader().download(try Self.stubRelease("missing"), to: file) { _ in }
    }
    let foreign = "https://evil.example/releases/darwin/arm64/Claude.zip"
    let stub = try Self.stubRelease("whole")
    let release = ClaudeRelease(version: stub.version, url: try #require(URL(string: foreign)), sha256: stub.sha256, size: stub.size)
    await #expect(throws: ClaudeUpdateFailure.untrustedURL(foreign)) {
      try await Self.stubbedDownloader().download(release, to: file) { _ in }
    }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test(.timeLimit(.minutes(1))) func cancellingTheCallerCancelsTheDownload() async throws {
    let file = try makeTempDir().appendingPathComponent("Claude.zip")
    let (started, signal) = AsyncStream.makeStream(of: Void.self)
    let downloader = Self.stubbedDownloader()
    let release = try Self.stubRelease("stalls")
    let task = Task { try await downloader.download(release, to: file) { _ in signal.yield() } }
    for await _ in started { break }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func theDownloadSessionKeepsNoCookiesCacheOrCredentials() {
    let config = ClaudeArchiveDownloader.configuration()
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
    #expect(config.httpCookieAcceptPolicy == .never)
    #expect(config.urlCache == nil)
    #expect(config.urlCredentialStorage == nil)
    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(config.timeoutIntervalForRequest == 60)
    #expect(config.timeoutIntervalForResource == 30 * 60)
  }
}

/// Values handed to a `@Sendable` callback, in order.
final class ClaudeInstallRecorder<Value: Sendable>: Sendable {
  private let values = Mutex<[Value]>([])

  func record(_ value: Value) { values.withLock { $0.append(value) } }
  var all: [Value] { values.withLock { $0 } }
}

/// Serves `payload` in-process (no network), by the URL's file name: `whole` (200 in four chunks), `missing` (404),
/// `cut` (half, then the connection drops), `stalls` (a quarter, then nothing until the task is cancelled).
final class ClaudeArchiveStubProtocol: URLProtocol, @unchecked Sendable {
  static let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let scenario = url.deletingPathExtension().lastPathComponent
    let body = scenario == "missing" ? Data("not found".utf8) : Self.payload
    let headers = ["Content-Length": String(body.count), "Content-Type": "application/zip"]
    guard let response = HTTPURLResponse(
      url: url, statusCode: scenario == "missing" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let quarter = body.count / 4
    switch scenario {
    case "cut":
      client?.urlProtocol(self, didLoad: body.prefix(quarter * 2))
      client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    case "stalls":
      client?.urlProtocol(self, didLoad: body.prefix(quarter))
    case "whole":
      for start in stride(from: 0, to: body.count, by: quarter) {
        client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + quarter, body.count)))
      }
      client?.urlProtocolDidFinishLoading(self)
    default:
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}
