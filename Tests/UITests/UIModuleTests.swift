import Testing
@testable import UI

@Suite struct UIModuleTests {
  @Test func moduleNameIsStable() {
    #expect(UIModule.name == "UI")
  }
}
