import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// «Добавить»: the request for an app named exactly as typed, its hidden slug and a profile left by a removed app.
@Suite(.russian) struct EditInstanceAddTests {
  private let home = URL(fileURLWithPath: "/Users/u", isDirectory: true)

  private func four(_ root: URL) throws -> [Instance] {
    let text = String(decoding: try fixtureData("instances-four.json"), as: UTF8.self)
      .replacingOccurrences(of: "{{ROOT}}", with: root.path)
    struct File: Decodable { let instances: [Instance] }
    return try JSONCoding.decoder.decode(File.self, from: Data(text.utf8)).instances
  }

  /// The app is named exactly as typed; "Claude " is not added.
  @Test func anAppNamedRequestKeepsTheNameAsTyped() throws {
    let request = NewInstanceRequest.app(named: "  Claude mv2 ", badge: " mv2 ", existing: [], home: home)
    #expect(request.displayName == "Claude mv2" && request.name == "Claude mv2")
    #expect(request.slug == "mv2" && request.badge == "mv2" && request.emails.isEmpty)
    #expect(request.target(applicationsDir: URL(fileURLWithPath: "/Applications")).path == "/Applications/Claude mv2.app")
    let spec = request.spec(home: home)
    #expect(spec.displayName == "Claude mv2" && spec.bundleId == "com.imaxzone.claude.mv2" && spec.badge == "mv2")
    #expect(spec.profileDir.path == "/Users/u/Library/Application Support/ClaudeProfiles/mv2")
    let plain = NewInstanceRequest.app(named: "Работа", badge: "Раб", existing: [], home: home)
    #expect(plain.displayName == "Работа" && plain.slug == "rabota")
  }

  /// The older request (`cmacc instance new`) still prefixes "Claude ".
  @Test func theCommandLineRequestStillPrefixesClaude() {
    let request = NewInstanceRequest(name: "Work", slug: "work", badge: "W", emails: [])
    #expect(request.displayName == "Claude Work")
    #expect(NewInstanceRequest(displayName: "Claude Work", slug: "work", badge: "W") != request)
  }

  @Test(arguments: [
    ("Claude mv2", "mv2"), ("claude-Work 2", "work-2"), ("Работа", "rabota"), ("Claude", "claude"),
    ("Claude2", "claude2"), ("🚀", "app"), ("Claude 🚀", "app"),
  ])
  func theHiddenSlugComesFromTheNameWithoutClaude(name: String, slug: String) {
    #expect(NewInstanceRequest.slug(forAppName: name, existing: [], home: home) == slug)
  }

  /// A slug, bundle id or profile folder already used by an instance gets "-2", "-3", …
  @Test func theHiddenSlugNeverClashesWithAnInstance() throws {
    let root = try makeTempDir()
    let existing = try four(root)
    #expect(NewInstanceRequest.slug(forAppName: "Claude Work", existing: existing, home: root) == "work-2")
    let taken = existing + [
      Instance(slug: testSlug("work-2"), name: "W2", kind: .clone),
      Instance(slug: testSlug("other"), name: "O", kind: .clone, bundleId: "com.imaxzone.claude.work-3"),
      Instance(slug: testSlug("old"), name: "Old", kind: .clone,
               profileDir: root.appendingPathComponent("Library/Application Support/ClaudeProfiles/work-4").path),
    ]
    #expect(NewInstanceRequest.slug(forAppName: "Claude Work", existing: taken, home: root) == "work-5")
  }

  @Test func aLongNameStillFitsTheSlugWithItsSuffix() {
    let long = "Claude " + String(repeating: "a", count: 40)
    let base = NewInstanceRequest.slug(forAppName: long, existing: [], home: home)
    #expect(base == String(repeating: "a", count: 32))
    let clash = Instance(slug: testSlug(base), name: "A", kind: .clone)
    let next = NewInstanceRequest.slug(forAppName: long, existing: [clash], home: home)
    #expect(next == String(repeating: "a", count: 30) + "-2")
    #expect((try? Slug(next)) != nil)
  }

  @Test func theBadgeSuggestionIsTheShortNameOrItsFirstThreeLetters() {
    #expect(NewInstanceRequest.suggestedBadge(forAppName: "Claude mv2") == "mv2")
    #expect(NewInstanceRequest.suggestedBadge(forAppName: "Claude Work") == "Work")
    #expect(NewInstanceRequest.suggestedBadge(forAppName: "Работа") == "Раб")
    #expect(NewInstanceRequest.suggestedBadge(forAppName: "Claude") == "Cla")
    #expect(NewInstanceRequest.suggestedBadge(forAppName: "  ") == "")
  }

  // MARK: Leftover profile

  private func profiles(_ root: URL) -> URL {
    root.appendingPathComponent("Library/Application Support/ClaudeProfiles", isDirectory: true)
  }

  @Test func aProfileFolderNoInstanceUsesIsALeftover() throws {
    let root = try makeTempDir()
    let folder = profiles(root).appendingPathComponent("mv2", isDirectory: true)
    #expect(LeftoverProfile.find(slug: "mv2", existing: [], home: root) == nil)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(LeftoverProfile.find(slug: "mv2", existing: [], home: root)?.path == folder.path)
    let owner = Instance(slug: testSlug("other"), name: "O", kind: .clone, profileDir: folder.path + "/")
    #expect(LeftoverProfile.find(slug: "mv2", existing: [owner], home: root) == nil)
    #expect(LeftoverProfile.find(slug: "Bad Slug", existing: [], home: root) == nil)
  }

  @Test func aFileOrALinkNamedLikeTheProfileIsNotALeftover() throws {
    let root = try makeTempDir()
    try FileManager.default.createDirectory(at: profiles(root), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: profiles(root).appendingPathComponent("file"))
    try FileManager.default.createSymbolicLink(
      at: profiles(root).appendingPathComponent("link"), withDestinationURL: root)
    #expect(LeftoverProfile.find(slug: "file", existing: [], home: root) == nil)
    #expect(LeftoverProfile.find(slug: "link", existing: [], home: root) == nil)
  }

  @Test func startingCleanMovesOnlyALeftoverToTheTrash() async throws {
    let root = try makeTempDir()
    let folder = profiles(root).appendingPathComponent("mv2", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let log = EventLog()
    let trash = EditFakeTrash(log: log)
    try await LeftoverProfile.trash(slug: "mv2", existing: [], home: root, trash: trash)
    #expect(log.all == ["trash(mv2)"])
    let owner = Instance(slug: testSlug("mv2"), name: "M", kind: .clone, profileDir: folder.path)
    await #expect(throws: LeftoverProfileError.notLeftover("mv2")) {
      try await LeftoverProfile.trash(slug: "mv2", existing: [owner], home: root, trash: trash)
    }
    #expect(log.all == ["trash(mv2)"])
  }
}
