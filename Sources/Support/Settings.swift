import Foundation

/// Contents of `settings.json`. Every key is optional on disk and falls back to `defaults`; keys of retired features
/// (`usage`, `router`, `remoteControl`) are ignored on load and dropped on the next save.
public struct AppSettings: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var builder: Builder
  public var updates: Updates
  public var ui: UI

  public static let defaults = AppSettings()

  public init(schemaVersion: Int = 1, builder: Builder = .init(), updates: Updates = .init(), ui: UI = .init()) {
    self.schemaVersion = schemaVersion
    self.builder = builder
    self.updates = updates
    self.ui = ui
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AppSettings()
    schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? d.schemaVersion
    builder = try c.decodeIfPresent(Builder.self, forKey: .builder) ?? d.builder
    updates = try c.decodeIfPresent(Updates.self, forKey: .updates) ?? d.updates
    ui = try c.decodeIfPresent(UI.self, forKey: .ui) ?? d.ui
  }

  public struct Builder: Codable, Sendable, Equatable {
    /// Retired and ignored; kept only so existing `settings.json` files decode and round-trip. Removing ShipIt meant
    /// re-signing `Squirrel.framework` with the local identity, and the vendor helpers (hardened runtime with library
    /// validation) then refuse to load it ("different Team IDs"), so clones never touch `Contents/Frameworks`.
    public var neutralizeUpdater: Bool
    public var signingIdentitySHA1: String?
    /// The dedicated keychain file holding `signingIdentitySHA1` (made by `SigningIdentityProvisioner`); `nil` means
    /// the identity is in the default keychain search list (`scripts/signing-setup.sh`, login keychain).
    public var signingKeychainPath: String?

    public init(neutralizeUpdater: Bool = true, signingIdentitySHA1: String? = nil, signingKeychainPath: String? = nil) {
      self.neutralizeUpdater = neutralizeUpdater
      self.signingIdentitySHA1 = signingIdentitySHA1
      self.signingKeychainPath = signingKeychainPath
    }

    public init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      neutralizeUpdater = try c.decodeIfPresent(Bool.self, forKey: .neutralizeUpdater) ?? true
      signingIdentitySHA1 = try c.decodeIfPresent(String.self, forKey: .signingIdentitySHA1)
      signingKeychainPath = try c.decodeIfPresent(String.self, forKey: .signingKeychainPath)
    }
  }

  public struct Updates: Codable, Sendable, Equatable {
    public var autoRebuild: Bool
    /// «Обновить» asks before it quits running clones; «Больше не спрашивать» turns it off.
    public var askBeforeRestart: Bool
    public init(autoRebuild: Bool = true, askBeforeRestart: Bool = true) {
      self.autoRebuild = autoRebuild
      self.askBeforeRestart = askBeforeRestart
    }
    public init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      autoRebuild = try c.decodeIfPresent(Bool.self, forKey: .autoRebuild) ?? true
      askBeforeRestart = try c.decodeIfPresent(Bool.self, forKey: .askBeforeRestart) ?? true
    }
  }

  public struct UI: Codable, Sendable, Equatable {
    public var launchAtLoginHintShown: Bool
    /// The copy whose «Переместить в «Программы»?» was answered «Не сейчас»; that copy is not asked again.
    public var moveDeclinedPath: String?
    public init(launchAtLoginHintShown: Bool = false, moveDeclinedPath: String? = nil) {
      self.launchAtLoginHintShown = launchAtLoginHintShown
      self.moveDeclinedPath = moveDeclinedPath
    }
    public init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      launchAtLoginHintShown = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginHintShown) ?? false
      moveDeclinedPath = try c.decodeIfPresent(String.self, forKey: .moveDeclinedPath)
    }
  }
}
