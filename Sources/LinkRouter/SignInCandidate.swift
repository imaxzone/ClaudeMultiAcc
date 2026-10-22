import Foundation
import os
import Support

/// A clone that can wait for sign-in: an app with its own bundle id and profile.
public struct SignInCandidate: Sendable, Equatable {
  public let slug: String
  public let bundleId: String
  public let appPath: URL
  public let profileDir: URL

  public init(slug: String, bundleId: String, appPath: URL, profileDir: URL) {
    self.slug = slug
    self.bundleId = bundleId
    self.appPath = appPath
    self.profileDir = profileDir
  }

  static let ownAppName = "ClaudeMultiAcc.app"

  /// Clones from the registry, in list order. The official app, CLI-only accounts, entries without an app or a
  /// profile and ClaudeMultiAcc itself never wait for sign-in, nor does an entry whose app declares another bundle id
  /// than the registry's (L6: its sign-in link would go to the wrong app). An app that cannot be read stays a
  /// candidate: `WorkspaceDelivery` refuses it.
  public static func clones(
    from instances: [Instance], ownBundleId: String = BuildInfo.bundleId,
    identify: (URL) -> String? = { AppIdentity.bundleId(of: $0) }
  ) -> [SignInCandidate] {
    instances.compactMap { instance in
      guard instance.kind == .clone, let bundleId = instance.bundleId, bundleId != ownBundleId,
        let appPath = instance.appPath, let profileDir = instance.profileDir
      else { return nil }
      let app = URL(fileURLWithPath: appPath)
      guard app.lastPathComponent != ownAppName else { return nil }
      if let found = identify(app), !AppIdentity.matches(found, bundleId) {
        let slug = instance.slug.raw
        OfficialApp.log.error(
          "\(slug, privacy: .public) never waits: \(app.path, privacy: .public) is \(found, privacy: .public)")
        return nil
      }
      return SignInCandidate(
        slug: instance.slug.raw, bundleId: bundleId, appPath: app,
        profileDir: URL(fileURLWithPath: profileDir, isDirectory: true))
    }
  }
}

/// Where links go when no clone waits: the official Claude.
public enum OfficialApp {
  public static let defaultPath = URL(fileURLWithPath: "/Applications/Claude.app")
  public static let bundleId = "com.anthropic.claudefordesktop"
  static let log = AppLog.logger("sign-in-router")

  /// The first `official` registry entry with an app, skipping one whose app declares another bundle id than the
  /// official Claude's (an app that cannot be read is kept: `WorkspaceDelivery` and `SchemeOwnership` refuse it).
  public static func from(
    _ instances: [Instance], identify: (URL) -> String? = { AppIdentity.bundleId(of: $0) }
  ) -> URL? {
    for instance in instances where instance.kind == .official {
      guard let path = instance.appPath else { continue }
      let app = URL(fileURLWithPath: path)
      if let found = identify(app), !AppIdentity.matches(found, bundleId) {
        log.error("Skipping official entry \(app.path, privacy: .public): it is \(found, privacy: .public)")
        continue
      }
      return app
    }
    return nil
  }

  /// `/Applications/Claude.app` when it is installed and really the official Claude; for the fallback when the
  /// registry names none.
  public static func installedDefault(identify: (URL) -> String? = { AppIdentity.bundleId(of: $0) }) -> URL? {
    AppIdentity.matches(identify(defaultPath), bundleId) ? defaultPath : nil
  }
}

/// Whether a Claude Desktop profile is signed in; faked in tests.
public protocol SignInStateReading: Sendable {
  func isSignedIn(profileDir: URL) -> Bool
}

/// Reads `<profile>/config.json` the way Claude itself decides "was signed in" at launch: `windowSizeWasSignedIn`
/// when it is a boolean (written `true` on sign-in, `false` on sign-out), else whether `lastKnownAccountUuid` is set.
/// Decodes ONLY those two keys (G4). No file → never signed in (a fresh profile); a file that cannot be read or parsed
/// counts as signed in, so a broken file never makes ClaudeMultiAcc take the scheme.
public struct ProfileSignInReader: SignInStateReading {
  private struct Config: Decodable {
    let windowSizeWasSignedIn: Bool?
    let lastKnownAccountUuid: String?

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      windowSizeWasSignedIn = try? c.decodeIfPresent(Bool.self, forKey: .windowSizeWasSignedIn)
      lastKnownAccountUuid = try? c.decodeIfPresent(String.self, forKey: .lastKnownAccountUuid)
    }

    private enum CodingKeys: String, CodingKey {
      case windowSizeWasSignedIn, lastKnownAccountUuid
    }
  }

  public init() {}

  public func isSignedIn(profileDir: URL) -> Bool {
    let file = profileDir.appendingPathComponent("config.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return false }
    guard let data = try? Data(contentsOf: file), let config = try? JSONDecoder().decode(Config.self, from: data) else {
      return true
    }
    return config.windowSizeWasSignedIn ?? (config.lastKnownAccountUuid != nil)
  }
}
