import Foundation
import Testing
@testable import Support

/// The language rules, the lookup with its fallbacks, and where the resource bundles are searched.
@Suite struct LocalizationTests {
  @Test func supportedLanguagesAreMatchedByTheirCode() {
    #expect(Localization.choose(from: ["ru-TR", "en-TR"]) == "ru")
    #expect(Localization.choose(from: ["en_GB", "ru"]) == "en")
    #expect(Localization.choose(from: ["de", "uk"]) == "en")
    #expect(Localization.choose(from: ["de", "ru"]) == "ru")
    #expect(Localization.choose(from: []) == "en")
    #expect(Localization.languages.contains(Localization.system))
  }

  @Test func aPinnedLanguageAlsoFixesTheFormattingLocale() {
    Localization.$pinned.withValue("ru") {
      #expect(Localization.language == "ru")
      #expect(Localization.locale.identifier == "ru_RU")
      #expect(Localization.list(["2nd", "mv2"]) == "2nd и mv2")
      #expect(Localization.list(["a", "b", "c"]) == "a, b и c")
      #expect(Localization.byteCount(632_000_000) == "632 МБ")
      #expect(Localization.byteCount(12_600_000_000) == "12,6 ГБ")
    }
    Localization.$pinned.withValue("en") {
      #expect(Localization.language == "en")
      #expect(Localization.list(["2nd", "mv2"]) == "2nd and mv2")
      #expect(Localization.byteCount(632_000_000) == "632 MB")
      #expect(Localization.byteCount(12_600_000_000) == "12.6 GB")
    }
    Localization.$pinned.withValue("de") { #expect(Localization.language == "en") }
  }

  @Test func theModuleTableHasBothLanguages() {
    #expect(SupportText.table.availableLanguages == ["en", "ru"])
  }

  @Test func draftProblemsReadInBothLanguages() {
    Localization.$pinned.withValue("en") {
      #expect(InstanceDraftProblem.nameTooLong(45).message == "No longer than 40 characters, now 45")
      #expect(InstanceDraftProblem.nameTaken("Claude Work").message == "“Claude Work” already exists — choose another name")
    }
    Localization.$pinned.withValue("ru") {
      #expect(InstanceDraftProblem.nameTooLong(45).message == "Не длиннее 40 знаков, сейчас 45")
      #expect(InstanceDraftProblem.nameTaken("Claude Работа").message == "«Claude Работа» уже есть — выберите другое название")
    }
  }

  @Test func aMissingKeyFallsBackToEnglishThenToTheKey() throws {
    let dir = try makeTempDir()
    let bundle = dir.appendingPathComponent("T.bundle", isDirectory: true)
    for (language, body) in [("en", #""only.en" = "English";"# + "\n" + #""both" = "two";"#), ("ru", #""both" = "два";"#)] {
      let lproj = bundle.appendingPathComponent("\(language).lproj", isDirectory: true)
      try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
      try Data(body.utf8).write(to: lproj.appendingPathComponent("Localizable.strings"))
    }
    let table = LocalizedTable(bundle: Bundle(url: bundle))
    Localization.$pinned.withValue("ru") {
      #expect(table.string("both") == "два")
      #expect(table.string("only.en") == "English")
      #expect(table.string("nowhere") == "nowhere")
    }
    #expect(LocalizedTable(bundle: nil).string("menu.edit") == "menu.edit")
    #expect(LocalizedTable(bundle: nil).availableLanguages.isEmpty)
  }

  /// `cmacc` runs from `Contents/Helpers` (and through `~/.local/bin/cmacc`): its bundles are in `Contents/Resources`.
  @Test func helperExecutablesLookInTheAppsResources() throws {
    let dir = try makeTempDir()
    let app = dir.appendingPathComponent("ClaudeMultiAcc.app", isDirectory: true)
    let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
    try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
    let cmacc = helpers.appendingPathComponent("cmacc")
    try Data().write(to: cmacc)
    let link = dir.appendingPathComponent("cmacc")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cmacc)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true).resolvingSymlinksInPath()
    for executable in [cmacc, link] {
      let places = ResourceBundles.candidates(
        mainResources: dir, mainBundle: dir, executable: executable, holderResources: nil, holderBundle: dir)
      #expect(places.map { $0.resolvingSymlinksInPath().path }.contains(resources.path), "\(executable.path)")
      #expect(Set(places.map(\.path)).count == places.count)
    }
  }
}
