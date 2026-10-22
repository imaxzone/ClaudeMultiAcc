import Foundation
import Testing
@testable import Support

@Suite struct SettingsTests {
  @Test func defaultsMatchSchema() {
    let d = AppSettings.defaults
    #expect(d.schemaVersion == 1)
    #expect(d.builder.neutralizeUpdater == true)
    #expect(d.builder.signingIdentitySHA1 == nil)
    #expect(d.builder.signingKeychainPath == nil)
    #expect(d.updates.autoRebuild == true)
    #expect(d.ui.launchAtLoginHintShown == false)
  }

  /// «Больше не спрашивать» in the restart confirmation: asked by default, and an older file without the key still asks.
  /// «Не сейчас» on «Переместить ClaudeMultiAcc в «Программы»?» is remembered for that copy only.
  @Test func moveDeclinedPathIsOptionalAndRoundTrips() throws {
    #expect(AppSettings.defaults.ui.moveDeclinedPath == nil)
    let json = #"{"ui":{"launchAtLoginHintShown":true,"moveDeclinedPath":"/Volumes/ClaudeMultiAcc/ClaudeMultiAcc.app"}}"#
    let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data(json.utf8))
    #expect(s.ui.moveDeclinedPath == "/Volumes/ClaudeMultiAcc/ClaudeMultiAcc.app" && s.ui.launchAtLoginHintShown)
    #expect(try JSONCoding.decoder.decode(AppSettings.self, from: JSONCoding.encoder.encode(s)) == s)
  }

  @Test func askBeforeRestartDefaultsToTrueAndRoundTrips() throws {
    #expect(AppSettings.defaults.updates.askBeforeRestart == true)
    let old = try JSONCoding.decoder.decode(AppSettings.self, from: Data(#"{"updates":{"autoRebuild":false}}"#.utf8))
    #expect(old.updates.askBeforeRestart == true && old.updates.autoRebuild == false)
    let off = try JSONCoding.decoder.decode(AppSettings.self, from: Data(#"{"updates":{"askBeforeRestart":false}}"#.utf8))
    #expect(off.updates.askBeforeRestart == false && off.updates.autoRebuild == true)
    let again = try JSONCoding.decoder.decode(AppSettings.self, from: JSONCoding.encoder.encode(off))
    #expect(again.updates.askBeforeRestart == false)
  }

  @Test func emptyObjectDecodesToDefaults() throws {
    let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data("{}".utf8))
    #expect(s == AppSettings.defaults)
  }

  @Test func partialObjectKeepsOtherDefaults() throws {
    let json = #"{"updates":{"autoRebuild":false}}"#
    let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data(json.utf8))
    #expect(s.updates.autoRebuild == false)
    #expect(s.updates.askBeforeRestart == true)
    #expect(s.ui == AppSettings.defaults.ui)
    #expect(s.builder == AppSettings.defaults.builder)
  }

  @Test func fullSchemaDecodesAndRoundTrips() throws {
    let json = """
      {"schemaVersion":1,
       "builder":{"neutralizeUpdater":false,"signingIdentitySHA1":"ABC"},
       "updates":{"autoRebuild":false,"askBeforeRestart":false},
       "ui":{"launchAtLoginHintShown":true}}
      """
    let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data(json.utf8))
    #expect(s.builder.signingIdentitySHA1 == "ABC")
    #expect(!s.updates.autoRebuild && !s.updates.askBeforeRestart)
    #expect(s.ui.launchAtLoginHintShown)
    let again = try JSONCoding.decoder.decode(AppSettings.self, from: JSONCoding.encoder.encode(s))
    #expect(again == s)
  }

  /// `builder.signingKeychainPath` (dedicated keychain made by `SigningIdentityProvisioner`) is optional: files written
  /// before it existed decode to `nil`, a set value round-trips, and `nil` is not written at all.
  @Test func signingKeychainPathIsOptionalAndRoundTrips() throws {
    let old = try JSONCoding.decoder.decode(
      AppSettings.self, from: Data(#"{"builder":{"neutralizeUpdater":false,"signingIdentitySHA1":"ABC"}}"#.utf8))
    #expect(old.builder.signingKeychainPath == nil)
    #expect(old.builder.signingIdentitySHA1 == "ABC")
    let path = "/Users/u/Library/Application Support/ClaudeMultiAcc/signing/cmacc-signing.keychain-db"
    let json = #"{"builder":{"signingIdentitySHA1":"ABC","signingKeychainPath":"\#(path)"}}"#
    let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data(json.utf8))
    #expect(s.builder.signingKeychainPath == path)
    #expect(s.builder.neutralizeUpdater == true)
    #expect(try JSONCoding.decoder.decode(AppSettings.self, from: JSONCoding.encoder.encode(s)) == s)
    let defaults = String(decoding: try JSONCoding.encoder.encode(AppSettings.defaults), as: UTF8.self)
    #expect(!defaults.contains("signingKeychainPath"))
    #expect(AppSettings.Builder(signingIdentitySHA1: "ABC", signingKeychainPath: path).signingKeychainPath == path)
  }

  @Test func encodesCamelCaseKeys() throws {
    let text = String(decoding: try JSONCoding.encoder.encode(AppSettings.defaults), as: UTF8.self)
    for key in ["schemaVersion", "neutralizeUpdater", "autoRebuild", "askBeforeRestart", "launchAtLoginHintShown"] {
      #expect(text.contains("\"\(key)\""), "missing \(key)")
    }
    for retired in ["usage", "router", "remoteControl"] {
      #expect(!text.contains("\"\(retired)\""), "\(retired)")
    }
  }

  /// A `settings.json` written while usage limits, the link router and Remote Control existed still loads (strictly
  /// too), whatever shape those retired objects have; the next write drops them.
  @Test func retiredKeysStillLoadAndAreDroppedOnTheNextWrite() throws {
    let json = """
      {"schemaVersion":1,
       "usage":{"cliProbe":{"enabled":true,"claudePath":"/x/claude"},"refreshSeconds":90,"staleAfterMinutes":10},
       "router":{"schemeOwnership":{"enabled":true},"rules":[{"kind":"email","value":"a@b.co","slug":"BAD SLUG"}]},
       "remoteControl":{"enabled":true,"capacity":2,"claudePath":"/opt/claude","rcExtra":[1,2]},
       "updates":{"autoRebuild":false},
       "ui":{"launchAtLoginHintShown":true}}
      """
    let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data(json.utf8))
    #expect(s.updates.autoRebuild == false)
    #expect(s.ui.launchAtLoginHintShown)
    let text = String(decoding: try JSONCoding.encoder.encode(s), as: UTF8.self)
    for retired in ["usage", "router", "remoteControl", "cliProbe", "refreshSeconds", "schemeOwnership"] {
      #expect(!text.contains("\"\(retired)\""), "\(retired)")
    }
    #expect(try JSONCoding.decoder.decode(AppSettings.self, from: Data(text.utf8)) == s)
  }

  /// Malformed retired objects never fail the file.
  @Test func malformedRetiredKeysAreIgnored() throws {
    for legacy in [#""on""#, "[1]", #"{"enabled":"yes","capacity":"x","claudePath":42}"#, "null"] {
      let retired = ["usage", "router", "remoteControl"].map { #""\#($0)":\#(legacy)"# }.joined(separator: ",")
      let json = #"{\#(retired),"ui":{"launchAtLoginHintShown":true}}"#
      let s = try JSONCoding.decoder.decode(AppSettings.self, from: Data(json.utf8))
      #expect(s.ui.launchAtLoginHintShown, "\(legacy)")
      #expect(s.updates == AppSettings.defaults.updates, "\(legacy)")
    }
  }
}

@Suite struct SettingsStoreTests {
  @Test func missingFileLoadsDefaults() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(file: dir.appendingPathComponent("settings.json"))
    #expect(await store.load() == AppSettings.defaults)
  }

  @Test func corruptFileLoadsDefaults() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("settings.json")
    try Data("not json".utf8).write(to: file)
    #expect(await SettingsStore(file: file).load() == AppSettings.defaults)
  }

  @Test func loadStrictReturnsDefaultsForMissingFile() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = SettingsStore(file: dir.appendingPathComponent("settings.json"))
    #expect(try await store.loadStrict() == AppSettings.defaults)
  }

  @Test func loadStrictAcceptsRetiredKeysAndTheNextSaveDropsThem() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("settings.json")
    try Data(#"""
      {"usage":{"refreshSeconds":45},"router":{"schemeOwnership":{"enabled":true}},
       "remoteControl":{"enabled":true,"capacity":4,"claudePath":null},"updates":{"autoRebuild":false}}
      """#.utf8).write(to: file)
    let store = SettingsStore(file: file)
    let loaded = try await store.loadStrict()
    #expect(loaded.updates.autoRebuild == false)
    let updated = try await store.update { s in
      var copy = s
      copy.ui.launchAtLoginHintShown = true
      return copy
    }
    #expect(updated.updates.autoRebuild == false && updated.ui.launchAtLoginHintShown)
    let text = try String(contentsOf: file, encoding: .utf8)
    for retired in ["usage", "router", "remoteControl"] {
      #expect(!text.contains("\"\(retired)\""), "\(retired)")
    }
  }

  @Test func loadStrictThrowsOnCorruptFile() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("settings.json")
    try Data(#"{"updates":{"autoRebuild":"yes"}}"#.utf8).write(to: file)
    let store = SettingsStore(file: file)
    await #expect {
      try await store.loadStrict()
    } throws: { error in
      guard case SettingsStoreError.corrupt(let path, _) = error else { return false }
      return path == file.path
    }
  }

  @Test func updateNeverOverwritesCorruptFile() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("settings.json")
    let original = Data(#"{"updates":{"autoRebuild":"yes"},"ui":{"launchAtLoginHintShown":false}}"#.utf8)
    try original.write(to: file)
    let store = SettingsStore(file: file)
    await #expect(throws: SettingsStoreError.self) {
      try await store.update { s in
        var copy = s
        copy.ui.launchAtLoginHintShown = true
        return copy
      }
    }
    #expect(try Data(contentsOf: file) == original)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names.count == 2)
    let aside = try #require(names.first { $0 != "settings.json" })
    #expect(aside.wholeMatch(of: /settings\.json\.corrupt-\d{8}-\d{6}/) != nil)
    #expect(try Data(contentsOf: dir.appendingPathComponent(aside)) == original)
  }

  @Test func updatePersistsAtomically() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("settings.json")
    let store = SettingsStore(file: file)
    let updated = try await store.update { s in
      var copy = s
      copy.updates.autoRebuild = false
      return copy
    }
    #expect(updated.updates.autoRebuild == false)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"])
    #expect(try posixPermissions(file) == 0o600)
    let reloaded = await SettingsStore(file: file).load()
    #expect(reloaded == updated)
    #expect(reloaded.updates.askBeforeRestart == true)
  }
}
