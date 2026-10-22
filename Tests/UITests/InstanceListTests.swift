import Foundation
import Support
import Testing
@testable import UI

@MainActor
@Suite struct InstanceListTests {
  static func paths() -> Paths {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("instance-list-\(UUID().uuidString)")
    return Paths(home: home)
  }

  @Test func reloadSeedsTheFirstRunAndCallsBack() async throws {
    let paths = Self.paths()
    let list = InstanceList(paths: paths)
    var calls = 0
    list.onChange = { calls += 1 }
    await list.reload()
    #expect(list.instances.map(\.slug.raw) == ["main"])
    #expect(FileManager.default.fileExists(atPath: paths.instancesFile.path))
    #expect(calls == 1)
  }

  @Test func reloadPicksUpAChangedFile() async throws {
    let paths = Self.paths()
    let list = InstanceList(paths: paths)
    await list.reload()
    let clone = Instance(slug: try Slug("mv2"), name: "Claude mv2", kind: .clone, builtBy: "cmacc")
    try await InstanceStore(paths: paths).save(list.instances + [clone])
    await list.reload()
    #expect(list.instances.map(\.slug.raw) == ["main", "mv2"])
    #expect(list.instance(slug: "mv2")?.name == "Claude mv2")
    #expect(list.instance(slug: "nope") == nil)
  }

  @Test func anUnreadableFileKeepsTheLastGoodList() async throws {
    let paths = Self.paths()
    let list = InstanceList(paths: paths)
    await list.reload()
    try Data("{\"schemaVersion\":1,".utf8).write(to: paths.instancesFile)
    await list.reload()
    #expect(list.instances.map(\.slug.raw) == ["main"])
  }
}
