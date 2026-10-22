import Testing
@testable import LinkRouter

@Suite struct LinkRouterModuleTests {
  @Test func moduleNameIsStable() {
    #expect(LinkRouterModule.name == "LinkRouter")
  }
}
