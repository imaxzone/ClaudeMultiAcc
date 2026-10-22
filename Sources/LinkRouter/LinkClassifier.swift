import Foundation

/// Tells sign-in links apart from every other `claude://` URL. The scheme must be `claude`; the host and the first
/// path segment are compared case-insensitively. Only the kind is returned: nothing from the link (address, token,
/// code) is kept.
public enum LinkClassifier {
  public static func classify(_ url: URL) -> LinkKind {
    guard url.scheme?.lowercased() == "claude" else { return .notClaude }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let host = (components?.host ?? "").lowercased()
    let first = (components?.path ?? "").split(separator: "/").first?.lowercased()
    switch (host, first) {
    case ("login", "google-auth"): return .googleAuth
    case ("claude.ai", "magic-link"): return .magicLink
    case ("claude.ai", "sso-callback"): return .ssoCallback
    default: return .other
    }
  }
}
