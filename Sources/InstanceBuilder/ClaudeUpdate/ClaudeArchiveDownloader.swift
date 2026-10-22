import Foundation
import os
import Support
import Synchronization

/// Downloads the full Claude archive the feed offered: one anonymous GET (no cookies, cache or credentials) of a
/// `ClaudeDownloadPolicy` URL, redirects followed only to another such URL. Only a complete 200 answer ever lands at
/// the destination; size and checksum are checked afterwards by `ClaudeSourceInstaller`.
public struct ClaudeArchiveDownloader: ClaudeArchiveDownloading {
  /// Longest silence between two packets.
  public static let requestTimeout: TimeInterval = 60
  /// The whole download (about 264 MB, on a slow line too).
  public static let resourceTimeout: TimeInterval = 30 * 60

  private let session: URLSession

  public init(session: URLSession = ClaudeArchiveDownloader.makeSession()) {
    self.session = session
  }

  /// A session with `configuration()`; every download brings its own task delegate.
  public static func makeSession() -> URLSession {
    URLSession(configuration: configuration())
  }

  /// Ephemeral session that stores and sends no cookies, credentials or cached responses.
  public static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = requestTimeout
    config.timeoutIntervalForResource = resourceTimeout
    config.waitsForConnectivity = false
    return config
  }

  /// The redirect rule: a redirect is followed only to another allowed download URL.
  static func allowsRedirect(to url: URL?) -> Bool {
    ClaudeDownloadPolicy.isAllowed(url)
  }

  /// The GET of the release's archive; `.untrustedURL` for a URL outside `ClaudeDownloadPolicy`.
  static func request(for release: ClaudeRelease) throws -> URLRequest {
    guard ClaudeDownloadPolicy.isAllowed(release.url) else {
      throw ClaudeUpdateFailure.untrustedURL(release.url.absoluteString)
    }
    var request = URLRequest(url: release.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    return request
  }

  /// Whatever is at `file` is removed first, so after a failure nothing is there. Throws `ClaudeUpdateFailure`, or
  /// `CancellationError` when the calling task is cancelled (which cancels the download).
  public func download(
    _ release: ClaudeRelease, to file: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let request = try Self.request(for: release)
    try Self.clear(file)
    try Task.checkCancellation()
    let delegate = ClaudeArchiveDownloadDelegate(expectedSize: release.size, destination: file, progress: progress)
    let task = session.downloadTask(with: request)
    task.delegate = delegate
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        delegate.attach(continuation)
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  /// Removes `file` (a symlink as a link) when anything is there.
  static func clear(_ file: URL) throws {
    var info = stat()
    guard lstat(file.path, &info) == 0 else { return }
    do {
      try FileManager.default.removeItem(at: file)
    } catch {
      throw ClaudeUpdateFailure.storage(String(describing: error))
    }
  }
}

/// One download's task delegate: applies the redirect rule, stops a download that grows past the release's size,
/// reports progress, moves a complete 200 answer to the destination and resumes the caller exactly once.
final class ClaudeArchiveDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
  private struct State {
    var continuation: CheckedContinuation<Void, any Error>?
    /// The outcome of a task that finished before the caller was attached (cancelled before it started).
    var outcome: Result<Void, any Error>?
    var failure: ClaudeUpdateFailure?
    var stored = false
  }

  private static let log = AppLog.logger("claude-update")

  private let state = Mutex(State())
  private let expectedSize: Int64
  private let destination: URL
  private let progress: @Sendable (Double) -> Void

  init(expectedSize: Int64, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
    self.expectedSize = expectedSize
    self.destination = destination
    self.progress = progress
  }

  /// The first thing this download refused (a redirect, too many bytes, the answer), if any.
  var failure: ClaudeUpdateFailure? { state.withLock { $0.failure } }

  /// The caller waiting for the outcome; resumed at once when the task already finished.
  func attach(_ continuation: CheckedContinuation<Void, any Error>) {
    let finished: Result<Void, any Error>? = state.withLock { state in
      if state.outcome == nil { state.continuation = continuation }
      return state.outcome
    }
    if let finished { continuation.resume(with: finished) }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard ClaudeArchiveDownloader.allowsRedirect(to: request.url) else {
      record(.untrustedURL(request.url?.absoluteString ?? ""))
      let host = request.url?.host() ?? "?"
      Self.log.notice("Claude download: refused a redirect to \(host, privacy: .public)")
      return nil
    }
    return request
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesWritten <= expectedSize else {
      record(.sizeMismatch(expected: expectedSize, actual: totalBytesWritten))
      downloadTask.cancel()
      return
    }
    progress(expectedSize > 0 ? Double(totalBytesWritten) / Double(expectedSize) : 1)
  }

  /// The temporary file is gone after this returns, so a good answer is moved now.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    if let refusal = Self.refusal(of: downloadTask.response) { record(refusal) }
    guard failure == nil else { return }
    do {
      try FileManager.default.moveItem(at: location, to: destination)
      state.withLock { $0.stored = true }
    } catch {
      record(.storage(String(describing: error)))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let outcome = outcome(error)
    if case .failure = outcome, state.withLock({ $0.stored }) {
      try? FileManager.default.removeItem(at: destination)
    }
    let continuation = state.withLock { state in
      defer { state.continuation = nil }
      if state.continuation == nil { state.outcome = outcome }
      return state.continuation
    }
    continuation?.resume(with: outcome)
  }

  /// Why the final answer is unusable: not HTTP, from outside `ClaudeDownloadPolicy`, or not 200.
  static func refusal(of response: URLResponse?) -> ClaudeUpdateFailure? {
    guard let http = response as? HTTPURLResponse else { return .network("no HTTP response") }
    guard ClaudeDownloadPolicy.isAllowed(http.url) else { return .untrustedURL(http.url?.absoluteString ?? "") }
    guard http.statusCode == 200 else { return .network("HTTP \(http.statusCode)") }
    return nil
  }

  private func record(_ failure: ClaudeUpdateFailure) {
    state.withLock { state in
      if state.failure == nil { state.failure = failure }
    }
  }

  /// A recorded refusal wins over the transport error it caused (a cancel); a cancel by the caller is a
  /// `CancellationError`.
  private func outcome(_ error: (any Error)?) -> Result<Void, any Error> {
    let (failure, stored) = state.withLock { ($0.failure, $0.stored) }
    if let failure { return .failure(failure) }
    if let error {
      if (error as? URLError)?.code == .cancelled { return .failure(CancellationError()) }
      return .failure(ClaudeUpdateFailure.network(error.localizedDescription))
    }
    return stored ? .success(()) : .failure(ClaudeUpdateFailure.network("the download ended without a file"))
  }
}
