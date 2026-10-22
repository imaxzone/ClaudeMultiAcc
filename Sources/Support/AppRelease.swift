import Foundation

/// A newer ClaudeMultiAcc release on GitHub that the menu can offer.
public struct AppReleaseInfo: Sendable, Equatable {
  public let version: String
  public let pageURL: URL

  public init(version: String, pageURL: URL) {
    self.version = version
    self.pageURL = pageURL
  }
}
