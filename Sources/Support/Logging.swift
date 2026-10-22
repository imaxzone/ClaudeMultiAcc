import Foundation
import os

/// Unified-logging entry point; every library log goes through here (G8).
public enum AppLog {
  public static let subsystem = BuildInfo.bundleId

  public static func logger(_ category: String) -> Logger {
    Logger(subsystem: subsystem, category: category)
  }
}

public enum FileLogError: Error, Equatable {
  case open(errno: Int32)
  case write(errno: Int32)
}

/// Append-only log file with secret redaction, mode 0600 and size-based rotation (`.1` … `.keep`).
/// Line format: `2026-09-24T01:02:03.456Z [category] message`.
public actor RedactingFileLog {
  private let url: URL
  private let maxBytes: Int
  private let keep: Int
  private let clock: any Clock
  private let fallback = AppLog.logger("file-log")
  private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  public init(url: URL, maxBytes: Int = 5_000_000, keep: Int = 2, clock: any Clock = SystemClock()) {
    self.url = url
    self.maxBytes = maxBytes
    self.keep = max(0, keep)
    self.clock = clock
  }

  public func write(_ line: String, category: String = "app") {
    let text = "\(clock.now.formatted(Self.timestampStyle)) [\(category)] \(SecretRedactor.redact(line))\n"
    let data = Data(text.utf8)
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let size = currentSize()
      if size > 0, size + data.count > maxBytes { try rotate() }
      try append(data)
    } catch {
      fallback.error("Cannot write log \(self.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  private func currentSize() -> Int {
    var info = stat()
    return stat(url.path, &info) == 0 ? Int(info.st_size) : 0
  }

  private func rotated(_ index: Int) -> URL {
    URL(fileURLWithPath: url.path + ".\(index)")
  }

  private func rotate() throws {
    let fm = FileManager.default
    guard keep > 0 else {
      try fm.removeItem(at: url)
      return
    }
    if fm.fileExists(atPath: rotated(keep).path) { try fm.removeItem(at: rotated(keep)) }
    for index in stride(from: keep - 1, through: 1, by: -1) where fm.fileExists(atPath: rotated(index).path) {
      try fm.moveItem(at: rotated(index), to: rotated(index + 1))
    }
    try fm.moveItem(at: url, to: rotated(1))
  }

  private func append(_ data: Data) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw FileLogError.open(errno: errno) }
    defer { close(fd) }
    guard fchmod(fd, 0o600) == 0 else { throw FileLogError.write(errno: errno) }
    let written = data.withUnsafeBytes { buffer in
      buffer.baseAddress.map { Foundation.write(fd, $0, buffer.count) } ?? 0
    }
    guard written == data.count else { throw FileLogError.write(errno: errno) }
  }
}
