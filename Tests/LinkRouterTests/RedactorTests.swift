import Foundation
import Testing
@testable import LinkRouter

@Suite struct RedactorTests {
  @Test func queryValuesAreRedactedKeysKept() {
    #expect(Redactor.redact(url("claude://claude.ai/new?q=ping")) == "claude://claude.ai/new?q=<redacted>")
    #expect(Redactor.redact(url("claude://login/google-auth?code=abc&hop_nonce=x"))
      == "claude://login/google-auth?code=<redacted>&hop_nonce=<redacted>")
    #expect(Redactor.redact(url("claude://resume?session=abc")) == "claude://resume?session=<redacted>")
    #expect(Redactor.redact(url("claude://claude.ai/x?flag")) == "claude://claude.ai/x?flag")
  }

  @Test func magicLinkFragmentAndEmailNeverSurvive() {
    let email = "nobody@example.com"
    let hex = "0123456789abcdef0123456789abcdef"
    let text = Redactor.redact(url("claude://claude.ai/magic-link#\(hex):\(base64(email))"))
    #expect(text == "claude://claude.ai/magic-link#<redacted>")
    #expect(!text.contains(hex))
    #expect(!text.contains(base64(email)))
  }

  @Test func emailsInPathOrQueryAreMasked() {
    #expect(Redactor.redact(url("claude://claude.ai/u/me@example.com")) == "claude://claude.ai/u/<email>")
    let text = Redactor.redact(url("claude://claude.ai/x?me%40example.com=1&login_hint=me%40example.com"))
    #expect(!text.contains("example.com"))
    #expect(!text.contains("me%40"))
  }

  @Test func longPathSegmentsAreTruncated() {
    let long = "session_0123456789abcdef0123456789abcdef0123"
    #expect(Redactor.redact(url("claude://claude.ai/code/\(long)")) == "claude://claude.ai/code/session_…")
    let forty = String(repeating: "x", count: 40)
    #expect(Redactor.redact(url("claude://claude.ai/\(forty)")) == "claude://claude.ai/\(forty)")
  }

  @Test func credentialsPortAndHostCaseAreNormalised() {
    #expect(Redactor.redact(url("claude://user:secret@CLAUDE.AI:8443/new")) == "claude://claude.ai/new")
  }

  @Test func tokensInAnyPositionAreCaughtBySecretRedactor() {
    let text = Redactor.redact(url("claude://claude.ai/sk-ant-api03-abcdef/x?code=zzz#frag"))
    #expect(!text.contains("abcdef"))
    #expect(!text.contains("zzz"))
    #expect(!text.contains("frag"))
    #expect(text.hasSuffix("#<redacted>"))
  }

  @Test func otherSchemesKeepTheirScheme() {
    #expect(Redactor.redact(url("https://example.com/a?b=c")) == "https://example.com/a?b=<redacted>")
  }
}
