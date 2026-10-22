import Testing
@testable import Support

@Suite struct SecretRedactorTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String
    var testDescription: String { input }
  }

  static let cases: [Case] = [
    Case(input: "key sk-ant-api03-AbC_d-9 end", expected: "key sk-ant-<redacted> end"),
    Case(input: "Authorization: Bearer abc.def-123", expected: "Authorization: Bearer <redacted>"),
    Case(input: "?code=XYZ123&state=s1", expected: "?code=<redacted>&state=<redacted>"),
    Case(input: "token=t1 access_token=a1#frag", expected: "token=<redacted> access_token=<redacted>#frag"),
    Case(input: "refresh_token=r1&hop_nonce=n1", expected: "refresh_token=<redacted>&hop_nonce=<redacted>"),
    Case(input: "anon_id=q1 session_key=k1 sessionKey=k2", expected: "anon_id=<redacted> session_key=<redacted> sessionKey=<redacted>"),
    Case(input: "CODE=Upper", expected: "CODE=<redacted>"),
    Case(input: "json \"code=abc\" x", expected: "json \"code=<redacted>\" x"),
    Case(input: "https://claude.ai/magic-link#abc123:xyz", expected: "https://claude.ai/magic-link#<redacted>"),
    Case(input: "user me.name+tag@example.co.uk here", expected: "user <email> here"),
    Case(input: "claude://claude.ai/new", expected: "claude://claude.ai/new"),
    Case(input: "barcode=1 is not a key", expected: "barcode=1 is not a key"),
    Case(input: "nothing secret", expected: "nothing secret"),
    // Prefixed keys: `\b` alone never matched after an underscore.
    Case(input: "?id_token=i1&sso_token=s1", expected: "?id_token=<redacted>&sso_token=<redacted>"),
    Case(input: "auth_code=a1 device_code=d1", expected: "auth_code=<redacted> device_code=<redacted>"),
    Case(input: "client_secret=c1 api_key=k1 password=p1", expected: "client_secret=<redacted> api_key=<redacted> password=<redacted>"),
    Case(input: "x_barcode=1 stays", expected: "x_barcode=1 stays"),
    // Any claude:// link that is not already in the redacted form (`Redactor`) is masked as a whole.
    Case(input: "open claude://claude.ai/new?q=private prompt", expected: "open claude://<redacted> prompt"),
    Case(input: "at claude://claude.ai/x#frag now", expected: "at claude://<redacted> now"),
    Case(input: "claude://user:pw@host/x", expected: "claude://<redacted>"),
    Case(input: "claude://claude.ai/code/session_0123456789abcdef0123456789abcdef0123",
         expected: "claude://<redacted>"),
    Case(input: "CLAUDE://claude.ai/new?prompt=hi", expected: "claude://<redacted>"),
    Case(input: "claude://claude.ai/new?q=<redacted>", expected: "claude://claude.ai/new?q=<redacted>"),
    Case(input: "claude://claude.ai/code/session_… x", expected: "claude://claude.ai/code/session_… x"),
    Case(input: "claude://claude.ai/u/<email>", expected: "claude://claude.ai/u/<email>"),
    Case(input: "claude://claude.ai/magic-link#abc:def", expected: "claude://claude.ai/magic-link#<redacted>"),
    Case(input: "claude://login/google-auth?code=abc&hop_nonce=x&flag",
         expected: "claude://login/google-auth?code=<redacted>&hop_nonce=<redacted>&flag"),
  ]

  @Test(arguments: cases)
  func redactsRule(_ c: Case) {
    #expect(SecretRedactor.redact(c.input) == c.expected)
  }

  @Test func redactsSeveralSecretsInOneString() {
    let input = "open claude://login?code=AAA&state=BBB for bob@example.com with Bearer sk-ant-xyz and magic-link#tok"
    let out = SecretRedactor.redact(input)
    #expect(out == "open claude://login?code=<redacted>&state=<redacted> for <email> with Bearer <redacted> and magic-link#<redacted>")
  }
}
