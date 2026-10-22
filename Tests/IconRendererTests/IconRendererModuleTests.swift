import Testing
@testable import IconRenderer

@Suite struct IconRendererModuleTests {
  @Test func moduleNameIsStable() {
    #expect(IconRendererModule.name == "IconRenderer")
  }
}
