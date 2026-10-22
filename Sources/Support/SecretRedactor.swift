import Foundation

/// Masks tokens, codes, nonces, magic-link fragments, emails and raw `claude://` links before anything is logged (G13).
public enum SecretRedactor {
  private struct Rule: Sendable {
    let regex: NSRegularExpression
    let template: String
  }

  /// `key=value` keys whose values are masked: the known ones plus any `<prefix>_token|code|secret|nonce|key`
  /// (`id_token`, `sso_token`, `auth_code`, `client_secret`, …). `barcode=` is not a key.
  private static let secretKeys = #"(?:[a-z0-9]+_)+(?:token|code|secret|nonce|key)|code|state|token|secret|password|"#
    + #"anon_id|sessionKey"#

  /// The form `LinkRouter.Redactor` logs links in: host, path segments of at most 40 characters, query values and
  /// fragment already `<redacted>`. A `claude://` link in any other form is replaced as a whole.
  private static let redactedLink = #"[a-z0-9.-]*(?:/[^\s/?#]{1,40})*"#
    + #"(?:\?[^\s=&#]{1,40}(?:=<redacted>)?(?:&[^\s=&#]{1,40}(?:=<redacted>)?)*)?(?:#<redacted>)?(?!\S)"#

  // Applied in this order; each rule sees the output of the previous one.
  private static let rules: [Rule] = [
    rule(#"sk-ant-[A-Za-z0-9_-]+"#, "sk-ant-<redacted>"),
    rule(#"Bearer\s+\S+"#, "Bearer <redacted>"),
    rule(#"(?i)\b("# + secretKeys + #")=[^&\s#"]+"#, "$1=<redacted>"),
    rule(#"magic-link#\S+"#, "magic-link#<redacted>"),
    rule(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
    rule(#"(?i)claude://(?!"# + redactedLink + #")\S+"#, "claude://<redacted>"),
  ]

  public static func redact(_ s: String) -> String {
    rules.reduce(s) { text, rule in
      rule.regex.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.template)
    }
  }

  private static func rule(_ pattern: String, _ template: String) -> Rule {
    do {
      return Rule(regex: try NSRegularExpression(pattern: pattern), template: template)
    } catch {
      // Patterns are compile-time constants; an invalid one is a programming error.
      preconditionFailure("Invalid redaction pattern \(pattern): \(error)")
    }
  }
}
