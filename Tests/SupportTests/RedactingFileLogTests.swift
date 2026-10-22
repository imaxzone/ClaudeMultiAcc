import Foundation
import Testing
@testable import Support

struct FixedClock: Clock {
  let now: Date
}

@Suite struct RedactingFileLogTests {
  @Test func writesFormattedRedactedLineWithMode0600() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("app.log")
    let clock = FixedClock(now: Date(timeIntervalSince1970: 1_790_211_723.456))
    let log = RedactingFileLog(url: url, clock: clock)
    await log.write("login code=SECRET for a@b.com", category: "router")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text == "2026-09-24T01:02:03.456Z [router] login code=<redacted> for <email>\n")
    #expect(try posixPermissions(url) == 0o600)
  }

  @Test func defaultCategoryIsApp() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("app.log")
    let log = RedactingFileLog(url: url, clock: FixedClock(now: Date(timeIntervalSince1970: 0)))
    await log.write("hello")
    #expect(try String(contentsOf: url, encoding: .utf8) == "1970-01-01T00:00:00.000Z [app] hello\n")
  }

  @Test func rotatesAtMaxBytesKeepingNFiles() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("rc.log")
    let log = RedactingFileLog(url: url, maxBytes: 100, keep: 2, clock: FixedClock(now: Date(timeIntervalSince1970: 0)))
    // Each line is 30 + 40 = 70 bytes, so every write after the first rotates.
    for i in 0..<5 {
      await log.write("line-\(i)" + String(repeating: "x", count: 34))
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names == ["rc.log", "rc.log.1", "rc.log.2"])
    #expect(try String(contentsOf: url, encoding: .utf8).contains("line-4"))
    #expect(try String(contentsOf: dir.appendingPathComponent("rc.log.1"), encoding: .utf8).contains("line-3"))
    #expect(try String(contentsOf: dir.appendingPathComponent("rc.log.2"), encoding: .utf8).contains("line-2"))
    for name in names {
      #expect(try posixPermissions(dir.appendingPathComponent(name)) == 0o600)
    }
  }

  @Test func appendsWhileUnderLimit() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("a.log")
    let log = RedactingFileLog(url: url, maxBytes: 10_000, keep: 2, clock: FixedClock(now: Date(timeIntervalSince1970: 0)))
    await log.write("one")
    await log.write("two")
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    #expect(lines.count == 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["a.log"])
  }
}
