import Foundation
import Synchronization

/// Runs subprocesses with posix_spawn in their own process group.
/// Timeout: SIGTERM to the group, then SIGKILL to the group after 2 s. After the child exits, output
/// readers get at most 2 s more, so a descendant that keeps the pipes open cannot stall the caller.
/// Exit code is the child's status, or 128 + signal number when it was killed by a signal.
/// Each of stdout and stderr keeps at most `outputLimit` bytes (16 MiB by default; every tool this app runs prints a
/// few KB); the rest is still read, so the child never blocks on a full pipe, but dropped and flagged in the result.
public struct SystemProcessRunner: ProcessRunning {
  static let killGrace: DispatchTimeInterval = .seconds(2)
  static let drainGrace: DispatchTimeInterval = .seconds(2)
  public static let defaultOutputLimit = 16 * 1024 * 1024

  private let outputLimit: Int

  public init(outputLimit: Int = SystemProcessRunner.defaultOutputLimit) {
    self.outputLimit = max(0, outputLimit)
  }

  public func run(_ request: ProcessRequest) async throws -> ProcessResult {
    let limit = outputLimit
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try Self.runBlocking(request, limit: limit) })
      }
    }
  }

  private static func runBlocking(_ request: ProcessRequest, limit: Int) throws -> ProcessResult {
    let child = try SpawnedProcess.spawn(request)
    let stop = Locked(false)
    let readers = DispatchGroup()
    let stdout = drain(child.stdoutFD, limit: limit, stop: stop, group: readers)
    let stderr = drain(child.stderrFD, limit: limit, stop: stop, group: readers)
    if let stdinFD = child.stdinFD { feed(request.stdin ?? Data(), to: stdinFD) }

    let status = Locked<Int32>(0)
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      status.set(child.waitForExit())
      exited.signal()
    }

    let timedOut = exited.wait(timeout: .now() + dispatchInterval(request.timeout)) == .timedOut
    if timedOut {
      killpg(child.pid, SIGTERM)
      if exited.wait(timeout: .now() + killGrace) == .timedOut {
        killpg(child.pid, SIGKILL)
        exited.wait()
      }
    }
    if readers.wait(timeout: .now() + drainGrace) == .timedOut {
      stop.set(true)
      readers.wait()
    }
    close(child.stdoutFD)
    close(child.stderrFD)
    let (out, outTruncated) = stdout.get()
    let (err, errTruncated) = stderr.get()
    if outTruncated || errTruncated {
      AppLog.logger("process").notice(
        "\(request.executable.lastPathComponent, privacy: .public): output over \(limit, privacy: .public) bytes was dropped")
    }
    return ProcessResult(
      exitCode: status.get(), stdout: out, stderr: err, timedOut: timedOut, stdoutTruncated: outTruncated,
      stderrTruncated: errTruncated)
  }

  /// Reads `fd` until EOF, or until `stop` is raised; polls so a stop request is noticed within 100 ms. Keeps the
  /// first `limit` bytes and reports whether more arrived.
  private static func drain(_ fd: Int32, limit: Int, stop: Locked<Bool>, group: DispatchGroup) -> Locked<(Data, Bool)> {
    let box = Locked((Data(), false))
    DispatchQueue.global(qos: .utility).async(group: group) {
      var collected = Data()
      var truncated = false
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while !stop.get() {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 100)
        if ready == 0 || (ready < 0 && errno == EINTR) { continue }
        guard ready > 0 else { break }
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
          let kept = min(count, limit - collected.count)
          if kept > 0 { collected.append(buffer, count: kept) }
          if kept < count { truncated = true }
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
          break
        }
      }
      box.set((collected, truncated))
    }
    return box
  }

  private static func feed(_ data: Data, to fd: Int32) {
    // A child that exits early must not kill us with SIGPIPE.
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    DispatchQueue.global(qos: .utility).async {
      let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
      } catch {
        AppLog.logger("process").debug("stdin write ended early: \(String(describing: error), privacy: .public)")
      }
    }
  }

  private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
    let (seconds, attoseconds) = duration.components
    let nanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !nanos.overflow else { return .never }
    return .nanoseconds(Int(clamping: nanos.partialValue + attoseconds / 1_000_000_000))
  }
}

/// Small lock-protected box shared between the runner's worker queues.
final class Locked<Value: Sendable>: Sendable {
  private let storage: Mutex<Value>
  init(_ value: Value) { storage = Mutex(value) }
  func get() -> Value { storage.withLock { $0 } }
  func set(_ value: Value) { storage.withLock { $0 = value } }
}
