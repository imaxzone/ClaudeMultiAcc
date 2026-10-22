import AppKit
import Foundation
import os
import Support

/// LaunchServices access for one URL scheme; faked in tests.
public protocol SchemeOwnershipAPI: Sendable {
  func currentHandler(scheme: String) -> URL?
  func setHandler(_ app: URL, scheme: String) async throws
  /// The bundle id `app` declares in its Info.plist, read fresh; nil when unreadable.
  func bundleIdentifier(of app: URL) -> String?
}

public enum ClaimResult: Sendable, Equatable {
  case alreadyOwned
  case claimed
  case failed(String)
}

public enum HandBackResult: Sendable, Equatable {
  /// Another app already holds the scheme; it is left alone.
  case notOurs
  case handedBack
  case failed(String)
}

/// Observes the `claude` scheme owner, takes it for ClaudeMultiAcc while a clone waits for sign-in and hands it
/// back to the official Claude afterwards (G13). Nothing else may change the handler.
public struct SchemeOwnership: Sendable {
  public static let scheme = "claude"

  private let api: SchemeOwnershipAPI
  private let ownApp: URL

  public init(api: SchemeOwnershipAPI, ownApp: URL) {
    self.api = api
    self.ownApp = ownApp
  }

  /// The live LaunchServices implementation. Its `setHandler` is reachable only through `claim()` / `handBack(to:)`.
  public static func system(ownApp: URL) -> SchemeOwnership {
    SchemeOwnership(api: SystemSchemeOwnershipAPI(), ownApp: ownApp)
  }

  public func owner() -> (bundleId: String?, path: URL?) {
    guard let path = api.currentHandler(scheme: Self.scheme) else { return (nil, nil) }
    return (Bundle(url: path)?.bundleIdentifier, path)
  }

  public func isOwnedByUs() -> Bool {
    api.currentHandler(scheme: Self.scheme).map { Self.same($0, ownApp) } ?? false
  }

  public func claim() async -> ClaimResult {
    if isOwnedByUs() { return .alreadyOwned }
    do {
      try await api.setHandler(ownApp, scheme: Self.scheme)
      return .claimed
    } catch {
      return .failed(String(describing: error))
    }
  }

  /// Gives the scheme to `app` only while ClaudeMultiAcc holds it; never to ClaudeMultiAcc itself, and only when `app`
  /// declares the official Claude's bundle id (L6: a wrong registry path never becomes every `claude://` link's handler).
  public func handBack(to app: URL) async -> HandBackResult {
    guard isOwnedByUs(), !Self.same(app, ownApp) else { return .notOurs }
    let found = api.bundleIdentifier(of: app)
    guard AppIdentity.matches(found, OfficialApp.bundleId) else {
      AppLog.logger("sign-in-router").error(
        "Not handing claude:// to \(app.path, privacy: .public): \(found ?? "no bundle id", privacy: .public)")
      return .failed("refused: \(app.path) is \(found ?? "not a readable app"), not \(OfficialApp.bundleId)")
    }
    do {
      try await api.setHandler(app, scheme: Self.scheme)
      return .handedBack
    } catch {
      return .failed(String(describing: error))
    }
  }

  static func same(_ a: URL, _ b: URL) -> Bool {
    a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath()
  }
}

/// `NSWorkspace`-backed LaunchServices access. Internal so nothing outside `SchemeOwnership` can change the handler.
struct SystemSchemeOwnershipAPI: SchemeOwnershipAPI {
  func currentHandler(scheme: String) -> URL? {
    guard let probe = URL(string: "\(scheme)://") else { return nil }
    return NSWorkspace.shared.urlForApplication(toOpen: probe)
  }

  func setHandler(_ app: URL, scheme: String) async throws {
    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
  }

  func bundleIdentifier(of app: URL) -> String? { AppIdentity.bundleId(of: app) }
}
