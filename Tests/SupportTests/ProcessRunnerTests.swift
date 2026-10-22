import Foundation
import Testing
@testable import Support

@Suite struct ProcessRunnerTests {
  let runner = SystemProcessRunner()

  func request(_ path: String, _ args: [String] = [], timeout: Duration = .seconds(10)) -> ProcessRequest {
    ProcessRequest(executable: URL(fileURLWithPath: path), arguments: args, timeout: timeout)
  }

  @Test func capturesStdout() async throws {
    let result = try await runner.run(request("/bin/echo", ["hi"]))
    #expect(result.stdoutText == "hi\n")
    #expect(result.exitCode == 0)
    #expect(result.timedOut == false)
    #expect(!result.stdoutTruncated && !result.stderrTruncated)
  }

  @Test func capturesAtMost16MiBPerStreamByDefault() {
    #expect(SystemProcessRunner.defaultOutputLimit == 16 * 1024 * 1024)
  }

  /// Each stream keeps its first `outputLimit` bytes and says it dropped the rest.
  @Test func outputBeyondTheLimitIsDroppedAndFlagged() async throws {
    let limited = SystemProcessRunner(outputLimit: 1000)
    let script = "head -c 5000 /dev/zero | tr '\\0' a; head -c 3000 /dev/zero | tr '\\0' b >&2"
    let result = try await limited.run(request("/bin/sh", ["-c", script]))
    #expect(result.exitCode == 0 && !result.timedOut)
    #expect(result.stdout == Data(repeating: UInt8(ascii: "a"), count: 1000) && result.stdoutTruncated)
    #expect(result.stderr == Data(repeating: UInt8(ascii: "b"), count: 1000) && result.stderrTruncated)
  }

  @Test func outputExactlyAtTheLimitIsNotFlagged() async throws {
    let result = try await SystemProcessRunner(outputLimit: 4).run(request("/bin/echo", ["abc"]))
    #expect(result.stdoutText == "abc\n" && !result.stdoutTruncated)
  }

  /// The pipe keeps being drained past the limit, so a chatty child finishes instead of blocking on a full pipe.
  @Test func chattyChildIsStillDrainedPastTheLimit() async throws {
    let limited = SystemProcessRunner(outputLimit: 16)
    let result = try await limited.run(request("/bin/sh", ["-c", "head -c 20000000 /dev/zero"], timeout: .seconds(20)))
    #expect(result.exitCode == 0 && !result.timedOut)
    #expect(result.stdout.count == 16 && result.stdoutTruncated)
  }

  @Test func capturesStderrAndExitCode() async throws {
    let result = try await runner.run(request("/bin/ls", ["/definitely/not/here"]))
    #expect(result.exitCode != 0)
    #expect(result.stderrText.contains("/definitely/not/here"))
  }

  @Test func timesOut() async throws {
    let start = ContinuousClock.now
    let result = try await runner.run(request("/bin/sleep", ["5"], timeout: .milliseconds(200)))
    #expect(result.timedOut)
    #expect(ContinuousClock.now - start < .seconds(3))
  }

  @Test func timeoutKillsGrandchildrenHoldingPipes() async throws {
    let start = ContinuousClock.now
    let result = try await runner.run(request("/bin/sh", ["-c", "sleep 30 & wait"], timeout: .milliseconds(200)))
    #expect(result.timedOut)
    #expect(ContinuousClock.now - start < .seconds(4))
  }

  @Test func exitedChildWithLingeringGrandchildReturnsPromptly() async throws {
    let start = ContinuousClock.now
    let result = try await runner.run(request("/bin/sh", ["-c", "echo done; sleep 10 &"], timeout: .seconds(10)))
    #expect(result.timedOut == false)
    #expect(result.exitCode == 0)
    #expect(result.stdoutText == "done\n")
    #expect(ContinuousClock.now - start < .seconds(4))
  }

  @Test func emptyEnvironmentIsEmpty() async throws {
    var req = request("/usr/bin/env")
    req.environment = [:]
    let result = try await runner.run(req)
    #expect(result.stdoutText == "")
    #expect(result.exitCode == 0)
  }

  @Test func explicitEnvironmentIsPassed() async throws {
    var req = request("/usr/bin/env")
    req.environment = ["CMACC_X": "1"]
    #expect(try await runner.run(req).stdoutText == "CMACC_X=1\n")
  }

  @Test func currentDirectoryHonoured() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var req = request("/bin/pwd")
    req.currentDirectory = dir
    let out = try await runner.run(req).stdoutText.trimmingCharacters(in: .newlines)
    #expect(URL(fileURLWithPath: out).resolvingSymlinksInPath() == dir.resolvingSymlinksInPath())
  }

  @Test func stdinIsPiped() async throws {
    var req = request("/bin/cat")
    req.stdin = Data("piped\n".utf8)
    #expect(try await runner.run(req).stdoutText == "piped\n")
  }

  @Test func stdinDefaultsToDevNull() async throws {
    let result = try await runner.run(request("/bin/cat", timeout: .seconds(3)))
    #expect(result.timedOut == false)
    #expect(result.stdoutText == "")
  }

  @Test func failedLaunchesDoNotLeakDescriptors() async throws {
    func openDescriptors() throws -> Int {
      try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
    _ = try? await runner.run(request("/no/such/binary")) // warm up lazily-opened resources
    let before = try openDescriptors()
    for _ in 0..<50 {
      _ = try? await runner.run(request("/no/such/binary"))
    }
    // A leak costs 2 descriptors per failed launch (100 here); the margin absorbs parallel suites.
    let after = try openDescriptors()
    #expect(after - before < 20)
  }

  @Test func missingExecutableThrows() async {
    await #expect(throws: ProcessRunnerError.self) {
      try await runner.run(request("/no/such/binary"))
    }
  }
}
