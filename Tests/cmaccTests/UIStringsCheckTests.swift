import Testing
@testable import cmacc

/// `cmacc ui strings` finds every module's tables from the test bundle and prints each sample in both languages.
@Suite struct UIStringsCheckTests {
  @Test func everyTableIsFoundWithBothLanguages() {
    let report = UIStringsCheck.report()
    #expect(report.complete, "\(report.lines)")
    #expect(report.lines.contains("en: Open at Login"))
    #expect(report.lines.contains("ru: Открывать при старте системы"))
    #expect(report.lines.contains("en: Everything — 12.6 GB") && report.lines.contains("ru: Всё — 12,6 ГБ"))
  }

  @Test func theUICommandRoutesTheStringsCheck() async throws {
    #expect(try await UISnapshotCommand().run(["strings"]) == ExitCode.success)
    #expect(UISnapshotCommand.parse(["strings"]) == nil)
  }
}
