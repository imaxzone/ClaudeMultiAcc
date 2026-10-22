import Foundation
import Support
import Synchronization
import Testing
@testable import InstanceBuilder

/// The real `SystemProcessRunner`, fenced for the opt-in keychain e2e (`SigningKeychainE2ETests`). It refuses, before
/// anything runs, every command that could touch a keychain other than the test one or make macOS show a keychain
/// password prompt to whoever sits at this Mac:
/// - only `/usr/bin/security`, `/usr/bin/codesign` and `/usr/bin/openssl`;
/// - no default/login keychain, no search-list writes (`list-keychains -s`), no trust settings, and no keychain path
///   outside `root`;
/// - `find-identity` and `codesign --sign` only right after a successful unlock of the test keychain;
/// - every timeout capped at 20 s, so a prompt could never wait for the owner.
/// The transcript never contains stdin (it carries passwords), only the `security -i` verb.
final class GuardedKeychainRunner: ProcessRunning {
  static let cap: Duration = .seconds(20)
  static let interactiveVerbs: Set<String> = ["create-keychain", "unlock-keychain", "import", "set-key-partition-list"]

  struct Refused: Error, CustomStringConvertible {
    let description: String
  }

  let root: String
  let keychain: String
  let transcript: E2ETranscript
  private let inner = SystemProcessRunner()
  private let state = Mutex<(unlockedJustNow: Bool, labels: [String])>((false, []))

  init(root: URL, keychain: URL, transcript: E2ETranscript) {
    // Plain paths: `standardizedFileURL` drops `/private` only for paths that already exist.
    self.root = root.path
    self.keychain = keychain.path
    self.transcript = transcript
  }

  /// `security -i <verb>` / `security <verb>` / `codesign …` / `openssl <verb>` for every command that ran.
  var labels: [String] { state.withLock { $0.labels } }

  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    let label: String
    do {
      label = try vet(request)
    } catch {
      transcript.add("REFUSED \(error)")
      throw error
    }
    var capped = request
    capped.timeout = min(request.timeout, Self.cap)
    let result = try await inner.run(capped)
    let unlocked = label == "security -i unlock-keychain" && result.exitCode == 0 && !result.timedOut
    state.withLock { $0.unlockedJustNow = unlocked; $0.labels.append(label) }
    transcript.add("\(label) → exit \(result.exitCode)\(result.timedOut ? " TIMED OUT" : "")")
    return result
  }

  private func vet(_ request: ProcessRequest) throws -> String {
    let args = request.arguments
    let unlockedJustNow = state.withLock { $0.unlockedJustNow }
    switch request.executable.path {
    case "/usr/bin/openssl":
      return "openssl \(args.first ?? "")"
    case "/usr/bin/codesign":
      try requireInsideRoot(args.filter { $0.hasPrefix("/") })
      if args.contains("--sign") {
        guard let index = args.firstIndex(of: "--keychain"), args.indices.contains(index + 1),
              args[index + 1] == keychain else { throw Refused(description: "codesign --sign without the test keychain") }
        guard unlockedJustNow else { throw Refused(description: "codesign --sign without an unlock right before") }
      }
      return "codesign \(args.first ?? "")"
    case "/usr/bin/security":
      return try vetSecurity(args, stdin: request.stdin, unlockedJustNow: unlockedJustNow)
    default:
      throw Refused(description: "unexpected tool \(request.executable.path)")
    }
  }

  private func vetSecurity(_ args: [String], stdin: Data?, unlockedJustNow: Bool) throws -> String {
    if args == ["-i"] {
      let text = String(decoding: stdin ?? Data(), as: UTF8.self)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
      let verb = String(text.prefix { $0 != " " })
      guard lines.count == 1, Self.interactiveVerbs.contains(verb) else {
        throw Refused(description: "security -i with an unexpected command")
      }
      try requireKeychainPathsInsideRoot(text.components(separatedBy: "\"").filter { $0.hasPrefix("/") })
      try forbid(text)
      return "security -i \(verb)"
    }
    try forbid(args.joined(separator: " "))
    try requireKeychainPathsInsideRoot(args)
    let verb = args.first ?? ""
    switch verb {
    case "list-keychains":
      guard args == ["list-keychains", "-d", "user"] else { throw Refused(description: "search-list write") }
    case "find-certificate":
      guard !args.contains(where: { $0.hasPrefix("/") }) else { throw Refused(description: "find-certificate with a path") }
    case "set-keychain-settings":
      guard args == [verb, keychain] else { throw Refused(description: "set-keychain-settings with lock options") }
    case "find-identity":
      guard args.last == keychain else { throw Refused(description: "find-identity outside the test keychain") }
      guard unlockedJustNow else { throw Refused(description: "find-identity without an unlock right before") }
    case "show-keychain-info", "lock-keychain", "delete-keychain":
      guard args == [verb, keychain] else { throw Refused(description: "\(verb) outside the test keychain") }
    default:
      throw Refused(description: "security \(verb) is not part of the e2e")
    }
    return "security \(verb)"
  }

  private func forbid(_ text: String) throws {
    for word in ["default-keychain", "login-keychain", "login.keychain", "/Library/Keychains", "trusted-cert",
                 "trust-settings"] where text.contains(word) {
      throw Refused(description: "forbidden: \(word)")
    }
  }

  private func requireKeychainPathsInsideRoot(_ tokens: [String]) throws {
    try requireInsideRoot(tokens.filter { $0.hasSuffix(".keychain-db") || $0.hasSuffix(".keychain") })
  }

  private func requireInsideRoot(_ paths: [String]) throws {
    for path in paths where !path.hasPrefix(root + "/") || path.split(separator: "/").contains("..") {
      throw Refused(description: "path outside the e2e root")
    }
  }
}

/// Appends e2e notes to `<dir>/e2e-transcript.txt` (no `print`); the scratch root is shown as `<root>`.
final class E2ETranscript: Sendable {
  let file: URL
  private let root: String
  private let lines = Mutex<[String]>([])

  init(file: URL, root: URL) {
    self.file = file
    self.root = root.path
  }

  func add(_ line: String) {
    let text = line.replacingOccurrences(of: root, with: "<root>")
    let all = lines.withLock { lines -> [String] in
      lines.append(text)
      return lines
    }
    try? Data((all.joined(separator: "\n") + "\n").utf8).write(to: file, options: .atomic)
  }
}

/// The e2e fence refuses before anything runs (no process is spawned by these cases).
@Suite struct GuardedKeychainRunnerTests {
  static let sha1 = String(repeating: "AB", count: 20)

  static func cases(root: String, keychain: String) -> [(String, [String], String?)] {
    let login = "/Users/u/Library/Keychains/login.keychain-db"
    return [
      ("/usr/bin/security", ["default-keychain", "-s", keychain], nil),
      ("/usr/bin/security", ["login-keychain", "-s", keychain], nil),
      ("/usr/bin/security", ["list-keychains", "-d", "user", "-s", keychain], nil),
      ("/usr/bin/security", ["find-identity", "-p", "codesigning", keychain], nil),
      ("/usr/bin/security", ["delete-keychain", "/private/tmp/other.keychain-db"], nil),
      ("/usr/bin/security", ["set-keychain-settings", "-t", "300", "-l", keychain], nil),
      ("/usr/bin/security", ["add-trusted-cert", "-d", "\(root)/c.pem"], nil),
      ("/usr/bin/security", ["-i"], "unlock-keychain -p \"s3cret\" \"\(login)\"\n"),
      ("/usr/bin/security", ["-i"], "unlock-keychain -p \"s3cret\" \"\(keychain)\"\nlist-keychains -d user -s \"\(keychain)\"\n"),
      ("/usr/bin/security", ["-i"], "default-keychain -s \"\(keychain)\"\n"),
      ("/usr/bin/codesign", ["--force", "--sign", sha1, "--keychain", keychain, "\(root)/a.app"], nil),
      ("/usr/bin/codesign", ["--force", "--sign", sha1, "\(root)/a.app"], nil),
      ("/usr/bin/codesign", ["--verify", "/Applications/Claude.app"], nil),
      ("/usr/bin/codesign", ["--verify", "\(root)/../../Applications/Claude.app"], nil),
      ("/usr/bin/security", ["delete-keychain", "\(root)/../x.keychain-db"], nil),
      ("/bin/sh", ["-c", "true"], nil),
    ]
  }

  @Test func refusesEverythingOutsideTheFence() async throws {
    let root = try makeTempDir()
    let keychain = root.appendingPathComponent("data/signing/cmacc-signing.keychain-db")
    let transcript = E2ETranscript(file: root.appendingPathComponent("t.txt"), root: root)
    let runner = GuardedKeychainRunner(root: root, keychain: keychain, transcript: transcript)
    for (tool, arguments, stdin) in Self.cases(root: root.path, keychain: keychain.path) {
      let request = ProcessRequest(
        executable: URL(fileURLWithPath: tool), arguments: arguments, timeout: .seconds(1), stdin: stdin.map { Data($0.utf8) })
      await #expect(throws: GuardedKeychainRunner.Refused.self, "\(tool) \(arguments)") { _ = try await runner.run(request) }
    }
    #expect(runner.labels.isEmpty, "nothing ran")
    let text = try String(contentsOf: transcript.file, encoding: .utf8)
    #expect(!text.contains("s3cret"), "stdin never reaches the transcript")
  }
}
