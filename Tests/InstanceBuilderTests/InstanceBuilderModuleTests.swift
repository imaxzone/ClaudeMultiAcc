import Testing
@testable import InstanceBuilder

@Suite struct InstanceBuilderModuleTests {
  @Test func moduleNameIsStable() {
    #expect(InstanceBuilderModule.name == "InstanceBuilder")
  }
}
