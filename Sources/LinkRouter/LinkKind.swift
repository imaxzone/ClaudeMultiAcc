import Foundation

/// What a `claude://` link asks for, as far as signing in is concerned (research §3.3). Only the sign-in kinds ever go
/// to a clone; everything else (chats, sessions, MCP and connector callbacks) is `other` and goes to the official Claude.
public enum LinkKind: String, Codable, Sendable, CaseIterable {
  /// The e-mail magic link, the Google callback and SSO: they finish signing in to an account.
  case magicLink, googleAuth, ssoCallback
  case other, notClaude

  public var isSignIn: Bool {
    switch self {
    case .magicLink, .googleAuth, .ssoCallback: true
    case .other, .notClaude: false
    }
  }
}
