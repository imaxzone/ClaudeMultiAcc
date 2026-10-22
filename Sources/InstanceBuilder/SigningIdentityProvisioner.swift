import Foundation
import os
import Support

/// Creates the permanent signing identity without Terminal (R2 item 2, experiment E2): a self-signed code-signing
/// certificate (same flags as `scripts/signing-setup.sh`) in a DEDICATED keychain file
/// `<data>/signing/cmacc-signing.keychain-db`, whose random password is kept beside it in `keychain-password` (0600).
/// Never touches the login keychain, the keychain search list or trust settings. Passwords never appear in argv or
/// any environment: `security -i` reads its commands from stdin, openssl the one-time PKCS#12 password too
/// (`-passout stdin`), and openssl runs with a fixed minimal environment. `signing/` is excluded from Time Machine.
/// The keychain never auto-locks (`set-keychain-settings` without `-l`/`-t`), and `Signer` unlocks it right before
/// every codesign run anyway (it is locked again after a restart).
public struct SigningIdentityProvisioner: Sendable {
  public static let keychainFileName = "cmacc-signing.keychain-db"
  static let validityDays = 3650
  static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
  /// Nothing inherited from the app's environment reaches openssl.
  static let opensslEnvironment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
  /// `create()`'s temporary `.provision-<UUID>/` (key.pem, cert.pem, identity.p12).
  static let workDirPrefix = ".provision-"
  static let lockFileName = ".provision.lock"
  static let lockAttempts = 240
  static let lockRetry: Duration = .milliseconds(250)

  private let paths: Paths
  private let runner: ProcessRunning
  private let clock: any Support.Clock
  private let log = AppLog.logger("signing")

  public init(paths: Paths, runner: ProcessRunning, clock: any Support.Clock = SystemClock()) {
    self.paths = paths
    self.runner = runner
    self.clock = clock
  }

  /// `<data>/signing/cmacc-signing.keychain-db`.
  public static func defaultKeychain(paths: Paths) -> URL {
    paths.signingDir.appendingPathComponent(keychainFileName)
  }

  /// The permanent identity, created on first use: an identity `SigningIdentityCheck` accepts (dedicated keychain,
  /// unlocked; else the author's login-keychain identity) → an intact dedicated keychain whose records were lost
  /// (recorded again) → a new dedicated keychain (an unusable old one is renamed aside, never deleted). A
  /// login-keychain identity recorded in settings but no longer found is never replaced silently.
  public func ensureIdentity() async throws -> SigningIdentity {
    tidySigningDir()
    let check = SigningIdentityCheck(paths: paths, runner: runner)
    if let identity = await check.permanentIdentity() { return identity }
    try FileManager.default.createDirectory(at: paths.signingDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.signingDir.path)
    excludeFromBackup(paths.signingDir)
    let lock = try await acquireLock()
    defer { lock.release() }
    if let identity = await check.permanentIdentity() { return identity }
    let builder = try await SettingsStore(file: paths.settingsFile).loadStrict().builder
    let recorded = builder.signingIdentitySHA1.flatMap { $0.isEmpty ? nil : $0.uppercased() }
    let customPath = builder.signingKeychainPath.flatMap { $0.isEmpty ? nil : $0 }
    if let recorded, customPath == nil { throw SigningKeychainError.recordedIdentityMissing(recorded) }
    let keychain = SigningKeychain(url: customPath.map { URL(fileURLWithPath: $0) } ?? Self.defaultKeychain(paths: paths))
    let sha1: String
    if let existing = try await existingIdentity(in: keychain, preferring: recorded) {
      log.info("adopting the signing identity \(existing, privacy: .public) already in \(keychain.url.lastPathComponent, privacy: .public)")
      sha1 = existing
    } else {
      try setAside(keychain)
      sha1 = try await create(keychain)
    }
    try await record(sha1, keychain: keychain)
    return .certificate(sha1: sha1, keychain: keychain.url)
  }

  /// nil when the keychain is missing or unusable (no password, the password refused, no identity inside). A
  /// timeout or launch failure is rethrown instead: a busy Mac must never cost a good keychain its identity (a new
  /// one changes every clone's designated requirement).
  private func existingIdentity(in keychain: SigningKeychain, preferring recorded: String?) async throws -> String? {
    guard FileManager.default.fileExists(atPath: keychain.url.path), keychain.hasStoredPassword else { return nil }
    do {
      try await keychain.unlock(runner: runner)
    } catch SigningKeychainError.unlockFailed, SigningKeychainError.passwordMissing, SigningKeychainError.unquotable {
      return nil
    }
    let result = try await runner.runTool(
      BuilderTool.security, ["find-identity", "-p", "codesigning", keychain.url.path], timeout: BuilderTool.shortTimeout)
    guard result.exitCode == 0 else { return nil }
    let hashes = SigningIdentityCheck.identities(in: result.stdoutText)
    if let recorded, hashes.contains(recorded) { return recorded }
    return hashes.sorted().first
  }

  /// Renames an unusable keychain (and its password) to `<name>.stale-<yyyyMMdd-HHmmss>` so nothing is lost.
  private func setAside(_ keychain: SigningKeychain) throws {
    let suffix = ".stale-\(Timestamp.stamp(clock.now))"
    for url in [keychain.url, keychain.passwordFile] where FileManager.default.fileExists(atPath: url.path) {
      log.error("setting aside unusable \(url.lastPathComponent, privacy: .public)")
      try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: url.path + suffix))
    }
  }

  // MARK: Creation

  private struct Material {
    let key: URL
    let certificate: URL
    let p12: URL
    var p12Password = ""
    var sha1 = ""

    init(_ work: URL) {
      key = work.appendingPathComponent("key.pem")
      certificate = work.appendingPathComponent("cert.pem")
      p12 = work.appendingPathComponent("identity.p12")
    }
  }

  private func create(_ keychain: SigningKeychain) async throws -> String {
    let fm = FileManager.default
    let dir = keychain.url.deletingLastPathComponent()
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    shredWorkDirs(in: dir) // the caller holds the provisioning lock, so none of them is live
    let work = dir.appendingPathComponent(Self.workDirPrefix + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { Self.shred(work) }
    let material = try await makeCertificate(Material(work))
    let before = try await searchList()
    let password = Self.randomHex(bytes: 32)
    try AtomicFile.write(Data(password.utf8), to: keychain.passwordFile, permissions: 0o600)
    do {
      try await makeKeychain(keychain, password: password, material: material)
      guard await SigningIdentityCheck.identityHashes(in: keychain, runner: runner).contains(material.sha1) else {
        throw SigningKeychainError.identityNotFound(keychain.url.path)
      }
      guard try await searchList() == before else { throw SigningKeychainError.searchListChanged }
    } catch {
      log.error("signing keychain creation failed: \(String(describing: error), privacy: .public)")
      await discard(keychain)
      throw error
    }
    log.info("created signing identity \(material.sha1, privacy: .public) in \(keychain.url.lastPathComponent, privacy: .public)")
    return material.sha1
  }

  private func makeCertificate(_ files: Material) async throws -> Material {
    var material = files
    try await openssl([
      "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "\(Self.validityDays)",
      "-subj", "/CN=\(SigningIdentityCheck.commonName)",
      "-addext", "keyUsage=critical,digitalSignature", "-addext", "extendedKeyUsage=codeSigning",
      "-keyout", material.key.path, "-out", material.certificate.path,
    ], step: "openssl req")
    material.p12Password = Self.randomHex(bytes: 16)
    // PKCS#12 files from OpenSSL 3 need -legacy for `security import`; the system LibreSSL has no such flag.
    let legacy = try await opensslKnowsLegacy() ? ["-legacy"] : []
    try await openssl(
      ["pkcs12", "-export"] + legacy + [
        "-inkey", material.key.path, "-in", material.certificate.path, "-out", material.p12.path, "-passout", "stdin",
      ], step: "openssl pkcs12", stdin: Data((material.p12Password + "\n").utf8))
    let fingerprint = try await openssl(
      ["x509", "-in", material.certificate.path, "-noout", "-fingerprint", "-sha1"], step: "openssl x509")
    material.sha1 = try Self.sha1(fromFingerprint: fingerprint.stdoutText)
    return material
  }

  private func makeKeychain(_ keychain: SigningKeychain, password: String, material: Material) async throws {
    let path = try SigningKeychain.quoted(keychain.url.path)
    let pass = try SigningKeychain.quoted(password)
    try await security("create-keychain -p \(pass) \(path)", step: "create-keychain", secrets: [password])
    try await runner.runChecked(BuilderTool.security, ["set-keychain-settings", keychain.url.path], timeout: BuilderTool.shortTimeout)
    try await keychain.unlock(runner: runner)
    let p12 = try SigningKeychain.quoted(material.p12.path)
    let p12Pass = try SigningKeychain.quoted(material.p12Password)
    try await security("import \(p12) -k \(path) -f pkcs12 -x -T /usr/bin/codesign -P \(p12Pass)",
                       step: "import", secrets: [material.p12Password])
    try await security("set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \(pass) \(path)",
                       step: "set-key-partition-list", secrets: [password])
  }

  /// Deletes a keychain this run just created (`delete-keychain` also drops it from the search list) and its password.
  private func discard(_ keychain: SigningKeychain) async {
    if FileManager.default.fileExists(atPath: keychain.url.path) {
      _ = try? await runner.runTool(BuilderTool.security, ["delete-keychain", keychain.url.path], timeout: BuilderTool.shortTimeout)
    }
    try? FileManager.default.removeItem(at: keychain.passwordFile)
  }

  /// Writes `signing/identity.json` and `builder.signingIdentitySHA1` / `builder.signingKeychainPath`.
  private func record(_ sha1: String, keychain: SigningKeychain) async throws {
    let identity = [
      "sha1": sha1, "commonName": SigningIdentityCheck.commonName, "keychain": keychain.url.path,
      "createdAt": clock.now.formatted(.iso8601),
    ]
    let data = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys, .withoutEscapingSlashes])
    try AtomicFile.write(data + Data("\n".utf8), to: paths.identityFile, permissions: 0o600)
    try await SettingsStore(file: paths.settingsFile).update { settings in
      var copy = settings
      copy.builder.signingIdentitySHA1 = sha1
      copy.builder.signingKeychainPath = keychain.url.path
      return copy
    }
  }

  // MARK: signing/ hygiene

  /// Every call: keeps an existing `signing/` out of Time Machine and shreds the work dirs a crash inside `create()`
  /// left there (an unencrypted key.pem and a PKCS#12). Only while the provisioning lock is free: a live `create()`
  /// in another process holds it for as long as its work dir exists.
  private func tidySigningDir() {
    let dir = paths.signingDir
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    excludeFromBackup(dir)
    guard !Self.workDirs(in: dir).isEmpty else { return }
    switch UpdateLock.acquire(lockURL) {
    case .acquired(let lock):
      shredWorkDirs(in: dir)
      lock.release()
    case .busy: log.info("signing provisioning in progress elsewhere; stale work dirs stay for now")
    case .failed(let code): log.error("signing lock unavailable (errno \(code, privacy: .public)); stale work dirs stay")
    }
  }

  /// Sets `isExcludedFromBackup` (an xattr on that directory only) unless it is set already.
  private func excludeFromBackup(_ dir: URL) {
    var url = dir
    guard (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) != true else { return }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try url.setResourceValues(values)
    } catch {
      log.error("could not exclude \(dir.lastPathComponent, privacy: .public) from backups: \(String(describing: error), privacy: .public)")
    }
  }

  /// Caller holds the provisioning lock.
  private func shredWorkDirs(in dir: URL) {
    for work in Self.workDirs(in: dir) {
      log.notice("removing the stale signing work dir \(work.lastPathComponent, privacy: .public)")
      Self.shred(work)
    }
  }

  /// Real directories (never symlinks) named exactly `.provision-<UUID>`.
  static func workDirs(in dir: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { name in
      name.hasPrefix(workDirPrefix) && UUID(uuidString: String(name.dropFirst(workDirPrefix.count))) != nil
    }
    .map { dir.appendingPathComponent($0, isDirectory: true) }
    .filter { isRealDirectory($0.path) }
  }

  private static func isRealDirectory(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
  }

  // MARK: Tools

  @discardableResult
  private func security(_ line: String, step: String, secrets: [String]) async throws -> ProcessResult {
    try await SigningKeychain.interactive(runner, line, secrets: secrets) {
      SigningKeychainError.commandFailed(step: step, stderr: $0)
    }
  }

  @discardableResult
  private func openssl(_ arguments: [String], step: String, stdin: Data? = nil) async throws -> ProcessResult {
    let request = ProcessRequest(
      executable: Self.openssl, arguments: arguments, environment: Self.opensslEnvironment, timeout: .seconds(120),
      stdin: stdin)
    let result = try await runner.run(request)
    if result.timedOut { throw BuilderError.commandTimedOut(Self.openssl.lastPathComponent) }
    guard result.exitCode == 0 else {
      throw SigningKeychainError.commandFailed(step: step, stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return result
  }

  private func opensslKnowsLegacy() async throws -> Bool {
    let request = ProcessRequest(
      executable: Self.openssl, arguments: ["pkcs12", "-help"], environment: Self.opensslEnvironment,
      timeout: BuilderTool.shortTimeout)
    let result = try await runner.run(request)
    return (result.stdoutText + result.stderrText).contains("-legacy")
  }

  /// `security list-keychains -d user` (read-only), compared before and after the keychain is created.
  private func searchList() async throws -> String {
    try await runner.runChecked(BuilderTool.security, ["list-keychains", "-d", "user"], timeout: BuilderTool.shortTimeout)
      .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var lockURL: URL { paths.signingDir.appendingPathComponent(Self.lockFileName) }

  private func acquireLock() async throws -> UpdateLock {
    for _ in 0..<Self.lockAttempts {
      switch UpdateLock.acquire(lockURL) {
      case .acquired(let lock): return lock
      case .busy: try await Task.sleep(for: Self.lockRetry)
      case .failed: throw SigningKeychainError.lockUnavailable
      }
    }
    throw SigningKeychainError.lockUnavailable
  }

  /// `SHA1 Fingerprint=95:A2:…` → `95A2…` (40 upper-case hex digits).
  static func sha1(fromFingerprint output: String) throws -> String {
    let hex = output.split(separator: "=").last.map { $0.replacingOccurrences(of: ":", with: "") }?
      .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    guard hex.count == 40, hex.allSatisfy(\.isHexDigit) else {
      throw SigningKeychainError.commandFailed(step: "openssl x509", stderr: "unexpected fingerprint: \(output)")
    }
    return hex
  }

  static func randomHex(bytes: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
  }

  /// Overwrites the temporary key, certificate and PKCS#12 files with zeros before removing the work directory.
  /// Only regular files are overwritten (`attributesOfItem` does not follow a symlink; a symlink is just removed).
  static func shred(_ dir: URL) {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
      let path = dir.appendingPathComponent(name).path
      guard let attributes = try? fm.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular
      else { continue }
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      if size > 0, let handle = FileHandle(forWritingAtPath: path) {
        try? handle.write(contentsOf: Data(count: size))
        try? handle.synchronize()
        try? handle.close()
      }
    }
    try? fm.removeItem(at: dir)
  }
}
