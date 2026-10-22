import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// What `SigningIdentityProvisioner` leaves behind and hands to openssl: no stale key material after a crash, no
/// password in any environment, and `signing/` kept out of Time Machine. Fakes only; no keychain is touched.
@Suite(.russian) struct SigningProvisionerHygieneTests {
  typealias Fixture = SigningIdentityProvisionerTests.Fixture

  func fixture(_ state: KeychainWorld.State = .init()) throws -> Fixture {
    try SigningIdentityProvisionerTests().fixture(state)
  }

  /// openssl gets a fixed two-variable environment (nothing inherited, no password in it) and the PKCS#12 password
  /// only on stdin; no other openssl run gets stdin.
  @Test func opensslRunsWithAMinimalEnvironmentAndThePasswordOnStdin() async throws {
    let f = try fixture()
    _ = try await f.provisioner.ensureIdentity()
    let openssl = f.runner.recorded.filter { $0.executable.path == "/usr/bin/openssl" }
    #expect(openssl.count == 4)
    let p12 = try #require(f.world.state.withLock { $0.p12Password })
    for request in openssl {
      #expect(request.environment == ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], "\(request.arguments)")
      #expect(!request.arguments.contains { $0.contains(p12) || $0.hasPrefix("env:") })
    }
    #expect(openssl.filter { $0.stdin != nil }.map { Array($0.arguments.prefix(2)) } == [["pkcs12", "-export"]])
    #expect(!f.runner.recorded.contains { ($0.environment ?? [:]).keys.contains("CMACC_P12_PASS") })
  }

  /// A crash inside `create()` leaves `.provision-<UUID>/` with an unencrypted key; the next call removes it.
  @Test func sweepsWorkDirsACrashLeftBehind() async throws {
    let f = try fixture()
    _ = try await f.provisioner.ensureIdentity()
    let stale = try plantWorkDir(f)
    _ = try await f.provisioner.ensureIdentity()
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: f.keychain.path))
  }

  @Test func sweepWaitsWhileAnotherProvisioningHoldsTheLock() async throws {
    let f = try fixture()
    _ = try await f.provisioner.ensureIdentity()
    let live = try plantWorkDir(f)
    guard case .acquired(let lock) = UpdateLock.acquire(f.paths.signingDir.appendingPathComponent(".provision.lock")) else {
      Issue.record("lock not acquired")
      return
    }
    _ = try await f.provisioner.ensureIdentity()
    #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent("key.pem").path))
    lock.release()
    _ = try await f.provisioner.ensureIdentity()
    #expect(!FileManager.default.fileExists(atPath: live.path))
  }

  /// Only real `.provision-<UUID>` directories are swept: a symlink is never followed, other names stay.
  @Test func sweepNeverFollowsSymlinksOrTouchesOtherNames() async throws {
    let f = try fixture()
    _ = try await f.provisioner.ensureIdentity()
    let outside = try makeTempDir()
    let kept = outside.appendingPathComponent("keep.txt")
    try Data("precious".utf8).write(to: kept)
    let link = f.paths.signingDir.appendingPathComponent(".provision-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let other = f.paths.signingDir.appendingPathComponent(".provision-notes", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    _ = try await f.provisioner.ensureIdentity()
    #expect(try Data(contentsOf: kept) == Data("precious".utf8))
    #expect(FileManager.default.fileExists(atPath: other.path))
  }

  @Test func signingDirIsExcludedFromTimeMachine() async throws {
    let f = try fixture()
    _ = try await f.provisioner.ensureIdentity()
    #expect(try f.paths.signingDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(try f.paths.dataDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
  }

  /// An install from before the exclusion existed gets it on the next call, even when nothing is created.
  @Test func existingSigningDirIsExcludedOnTheFastPath() async throws {
    var state = KeychainWorld.State()
    state.loginIdentities = [testSHA1]
    let f = try fixture(state)
    try installIdentity(f.paths)
    #expect(try f.paths.signingDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
    _ = try await f.provisioner.ensureIdentity()
    #expect(try f.paths.signingDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }

  /// The hints name the automatic setup (first + Add, before every build), not the retired Settings window or the
  /// login-keychain script that the app no longer ships in its Help.
  @Test func signingSetupHintsPointAtTheAutomaticSetup() {
    #expect(SigningSetup.hint.contains("+ Add") && SigningSetup.hint.contains("before every build"))
    #expect(SigningSetup.userHint.contains("«+ Добавить»") && SigningSetup.userHint.contains("перед каждой сборкой"))
    for text in [SigningSetup.hint, SigningSetup.userHint] {
      for stale in ["Resources/Help", "signing-setup.sh", "Настройки", "Терминал", "login"] {
        #expect(!text.contains(stale), "\(text)")
      }
    }
  }

  /// `signing/.provision-<UUID>/key.pem` as a crashed `create()` leaves it.
  private func plantWorkDir(_ f: Fixture) throws -> URL {
    let dir = f.paths.signingDir.appendingPathComponent(".provision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    try Data("unencrypted key".utf8).write(to: dir.appendingPathComponent("key.pem"))
    try Data("p12".utf8).write(to: dir.appendingPathComponent("identity.p12"))
    return dir
  }
}
