import AppKit
import Foundation
import os
import Support

/// Opens a URL in a specific app by path (never by scheme lookup, G13).
public protocol URLDelivering: Sendable {
  func deliver(_ url: URL, to app: URL, activate: Bool) async throws
}

/// Which app a path really is, from its own `Contents/Info.plist`, read fresh every time (`Bundle(url:)` caches bundles
/// by path, so an app replaced on disk could still answer with the old id).
public enum AppIdentity {
  static let clonePrefix = "com.imaxzone.claude."
  static let legacySecondId = "com.anthropic.claudefordesktop2"

  /// `CFBundleIdentifier` of the app at `app`; nil when there is no readable Info.plist.
  public static func bundleId(of app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    return plist["CFBundleIdentifier"] as? String
  }

  /// Whether `found` is `expected`, letter case ignored as LaunchServices does; nil never matches.
  public static func matches(_ found: String?, _ expected: String) -> Bool {
    found.map { $0.lowercased() == expected.lowercased() } ?? false
  }

  /// Claude Desktop or one of its clones: the vendor id, the legacy `com.anthropic.claudefordesktop2` or
  /// `com.imaxzone.claude.<slug>` (letter case ignored).
  public static func isClaudeDesktop(_ bundleId: String) -> Bool {
    let id = bundleId.lowercased()
    if id == OfficialApp.bundleId || id == legacySecondId { return true }
    guard id.hasPrefix(clonePrefix) else { return false }
    return (try? Slug(String(id.dropFirst(clonePrefix.count)))) != nil
  }
}

/// Why a link was not opened. English, for the log.
public enum DeliveryError: Error, Equatable, CustomStringConvertible {
  /// The app at `path` is not Claude Desktop or a clone (or is ClaudeMultiAcc itself); `bundleId` is what it declares.
  case unexpectedApp(path: String, bundleId: String?)

  public var description: String {
    switch self {
    case .unexpectedApp(let path, let bundleId):
      "refused to open a link in \(path): its bundle id \(bundleId ?? "is unreadable") is not a Claude app"
    }
  }
}

/// `NSWorkspace.open(_:withApplicationAt:configuration:)` without creating a new instance or prompting. The target's
/// own Info.plist must name Claude Desktop or a clone, never ClaudeMultiAcc: a wrong path in the registry never gets
/// a sign-in link (L6).
public struct WorkspaceDelivery: URLDelivering {
  private let identify: @Sendable (URL) -> String?
  private let ownBundleId: String

  public init(
    identify: @escaping @Sendable (URL) -> String? = { AppIdentity.bundleId(of: $0) },
    ownBundleId: String = BuildInfo.bundleId
  ) {
    self.identify = identify
    self.ownBundleId = ownBundleId
  }

  public func deliver(_ url: URL, to app: URL, activate: Bool) async throws {
    try check(app)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activate
    configuration.createsNewApplicationInstance = false
    configuration.promptsUserIfNeeded = false
    _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
  }

  /// Throws `DeliveryError.unexpectedApp` unless `app` declares Claude Desktop or a clone (and not ClaudeMultiAcc).
  func check(_ app: URL) throws {
    let found = identify(app)
    guard let found, AppIdentity.isClaudeDesktop(found), !AppIdentity.matches(found, ownBundleId) else {
      AppLog.logger("sign-in-router").error(
        "Refused a link for \(app.path, privacy: .public): \(found ?? "no bundle id", privacy: .public)")
      throw DeliveryError.unexpectedApp(path: app.path, bundleId: found)
    }
  }

  /// The error text for the log, with links, codes and addresses masked (G13).
  public static func failureDetail(_ error: any Error) -> String {
    SecretRedactor.redact(String(describing: error))
  }
}
