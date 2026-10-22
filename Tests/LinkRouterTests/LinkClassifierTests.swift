import Foundation
import Testing
@testable import LinkRouter

@Suite struct LinkClassifierTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let url: String
    let kind: LinkKind
    var testDescription: String { url }
  }

  static let hex = "0123456789abcdef0123456789abcdef"

  static let rows: [Row] = [
    Row(url: "claude://claude.ai/magic-link#\(hex):\(base64("Nobody@Example.com"))", kind: .magicLink),
    Row(url: "claude://CLAUDE.AI/magic-link#\(hex):\(base64("a.b@example.org"))", kind: .magicLink),
    Row(url: "claude://claude.ai/magic-link#\(hex):not_base64!!", kind: .magicLink),
    Row(url: "claude://claude.ai/magic-link", kind: .magicLink),
    Row(url: "claude://login/google-auth?code=abc&hop_nonce=x", kind: .googleAuth),
    Row(url: "claude://LOGIN/google-auth?code=abc&state=s&extra=1", kind: .googleAuth),
    Row(url: "claude://claude.ai/sso-callback?code=1&state=2", kind: .ssoCallback),
    Row(url: "claude://claude.ai/chat/magic-link", kind: .other),
    Row(url: "claude://example.com/magic-link#\(hex)", kind: .other),
    Row(url: "claude://login/apple-auth?code=1", kind: .other),
    Row(url: "claude://claude.ai/epitaxy/local_1111aaaa", kind: .other),
    Row(url: "claude://code/continue?session=local_2222bbbb", kind: .other),
    Row(url: "claude://code/needs-input?session=local_3333cccc&x=1", kind: .other),
    Row(url: "claude://claude.ai/code/session_01ABC", kind: .other),
    Row(url: "claude://claude.ai/code/cse_42xyz", kind: .other),
    Row(url: "claude://claude.ai/mcp-auth-callback?code=1", kind: .other),
    Row(url: "claude://claude.ai/settings/connectors?authed_mcp_server_id=srv_1", kind: .other),
    Row(url: "claude://claude.ai/chat/abc?gcal_success=true", kind: .other),
    Row(url: "claude://claude.ai/settings?oauth_error=denied&oauth_error_description=nope", kind: .other),
    Row(url: "claude://claude.ai/new", kind: .other),
    Row(url: "claude://claude.ai/new?q=ping", kind: .other),
    Row(url: "claude://code/new", kind: .other),
    Row(url: "claude://cowork/new?folder=x", kind: .other),
    Row(url: "claude://resume?session=abc", kind: .other),
    Row(url: "claude://claude.ai/chat/0f0f-1234", kind: .other),
    Row(url: "claude://claude.ai/project/p-1", kind: .other),
    Row(url: "claude://claude.ai/settings", kind: .other),
    Row(url: "claude://claude.ai/", kind: .other),
    Row(url: "claude://code/continue?session=bogus", kind: .other),
    Row(url: "claude:opaque", kind: .other),
    Row(url: "CLAUDE://claude.ai/new", kind: .other),
    Row(url: "https://claude.ai/new", kind: .notClaude),
    Row(url: "msauth.com.anthropic://auth", kind: .notClaude),
  ]

  @Test(arguments: rows)
  func classifies(_ row: Row) {
    #expect(LinkClassifier.classify(url(row.url)) == row.kind)
  }

  @Test func tableHasAtLeast25Urls() {
    #expect(Self.rows.count >= 25)
  }

  /// Only these finish a sign-in; sessions, MCP and connector callbacks belong to an app that is already signed in.
  @Test func signInKindsAreMagicLinkGoogleAndSso() {
    #expect(LinkKind.allCases.filter(\.isSignIn) == [.magicLink, .googleAuth, .ssoCallback])
    #expect(LinkKind.allCases == [.magicLink, .googleAuth, .ssoCallback, .other, .notClaude])
  }
}
