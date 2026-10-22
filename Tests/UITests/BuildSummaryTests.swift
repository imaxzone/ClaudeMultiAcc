import Testing
@testable import UI

/// The editor and the update dialogs speak the UI language (Russian here), never the pipeline's step ids.
@Suite(.russian) struct BuildSummaryTests {
  @Test func stepTitlesAreRussianWithAFallback() {
    #expect(BuildSummary.stepTitle("copy") == "Копирование приложения")
    #expect(BuildSummary.stepTitle("sign") == "Подпись")
    #expect(BuildSummary.stepTitle("new-step") == "new-step")
  }

  @Test(arguments: [(1, "приложение"), (2, "приложения"), (5, "приложений"), (11, "приложений"), (12, "приложений"),
                    (21, "приложение"), (22, "приложения"), (114, "приложений")])
  func pluralFollowsRussianRules(count: Int, expected: String) {
    #expect(UIText.format("update.confirm-title.many", count) == "Перезапустить и обновить \(count) \(expected)?")
  }
}
