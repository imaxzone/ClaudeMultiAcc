import AppKit
import Foundation
import InstanceBuilder
import Support
import Testing
@testable import UI

/// Representative UI strings in both languages, read from the module's own `.lproj` tables.
@MainActor
@Suite struct LocalizedStringsTests {
  @Test func theModuleTableHasBothLanguages() {
    #expect(UIText.table.availableLanguages == ["en", "ru"])
  }

  @Test(.english) func menuInEnglish() {
    #expect(AppMenuStrings.edit == "Edit…")
    #expect(AppMenuStrings.showInFinder == "Show in Finder")
    #expect(AppMenuStrings.delete(name: "Claude 2nd") == "Delete “Claude 2nd”…")
    #expect(AppMenuStrings.updateTo(version: "3.1700.0") == "Update to 3.1700.0")
    #expect(AppMenuStrings.launchAtLogin == "Open at Login")
    #expect(AppMenuStrings.quit == "Quit")
    #expect(AppMenuStrings.add == "Add" && AppMenuStrings.addLabel == "Add App")
    #expect(AppMenuStrings.bannerTitle(version: "3.1700.0") == "New version 3.1700.0")
    #expect(AppMenuStrings.bannerSubtitle(names: ["2nd", "mv2"]) == "for 2nd and mv2")
    #expect(AppMenuStrings.updateButton(count: 1) == "Update" && AppMenuStrings.updateButton(count: 2) == "Update 2")
    #expect(AppMenuStrings.statusItem(parts: [AppMenuStrings.statusUpdateAvailable(version: "3.1700.0", names: ["2nd"])])
      == "ClaudeMultiAcc — a new version 3.1700.0 is available for 2nd")
    #expect(AppMenuStrings.statusDeleting(names: ["Claude 2nd", "Claude mv2"]) == "deleting “Claude 2nd” and “Claude mv2”")
    #expect(LaunchAtLoginState.needsApproval.subtitle == "Allow in System Settings")
    #expect(AppMainMenu.make().items.compactMap(\.submenu?.title) == ["ClaudeMultiAcc", "Edit", "Window"])
  }

  @Test(.russian) func menuInRussian() {
    #expect(AppMenuStrings.edit == "Изменить…")
    #expect(AppMenuStrings.delete(name: "Claude 2nd") == "Удалить «Claude 2nd»…")
    #expect(AppMenuStrings.bannerSubtitle(names: ["2nd", "mv2"]) == "для 2nd и mv2")
    #expect(AppMenuStrings.statusDeleting(names: ["Claude mv2"]) == "удаляется «Claude mv2»")
    #expect(AppMenuStrings.statusDeleting(names: ["Claude 2nd", "Claude mv2"]) == "удаляются «Claude 2nd» и «Claude mv2»")
    #expect(AppMainMenu.make().items.compactMap(\.submenu?.title) == ["ClaudeMultiAcc", "Правка", "Окно"])
  }

  @Test func updateDialogTitleCountsAppsInBothLanguages() {
    let names = { (count: Int) in (1...count).map { "Claude \($0)" } }
    Localization.$pinned.withValue("ru") {
      #expect(UpdateFlowText.confirmTitle(names: ["Claude 2nd"]) == "Перезапустить «Claude 2nd» и обновить?")
      #expect(UpdateFlowText.confirmTitle(names: names(2)) == "Перезапустить и обновить 2 приложения?")
      #expect(UpdateFlowText.confirmTitle(names: names(5)) == "Перезапустить и обновить 5 приложений?")
      #expect(UpdateFlowText.confirmTitle(names: names(21)) == "Перезапустить и обновить 21 приложение?")
      #expect(UpdateFlowText.confirmTitle(names: names(22)) == "Перезапустить и обновить 22 приложения?")
    }
    Localization.$pinned.withValue("en") {
      #expect(UpdateFlowText.confirmTitle(names: ["Claude 2nd"]) == "Restart “Claude 2nd” and update?")
      #expect(UpdateFlowText.confirmTitle(names: names(2)) == "Restart and update 2 apps?")
      #expect(UpdateFlowText.confirmTitle(names: names(21)) == "Restart and update 21 apps?")
      #expect(UpdateFlowText.dontAskAgain == "Don’t ask again")
    }
  }

  @Test func deleteDialogShowsSizesInTheLanguagesLocale() {
    func text() -> DeleteDialogText {
      DeleteDialogText(
        name: "Claude mv2", app: URL(fileURLWithPath: "/Applications/Claude mv2.app"), appOnlyBytes: 632_000_000,
        profileBytes: 11_968_000_000, hasOldCopies: false, profileReusable: false)
    }
    Localization.$pinned.withValue("ru") {
      let ru = text()
      #expect(ru.title == "Удалить «Claude mv2»?")
      #expect(ru.appOnly.title == "Только приложение — 632 МБ")
      #expect(ru.everything.title == "Всё — 12,6 ГБ")
      #expect(ru.appOnly.removes == "Удалится: Claude mv2 из папки «Программы»")
    }
    Localization.$pinned.withValue("en") {
      let en = text()
      #expect(en.title == "Delete “Claude mv2”?")
      #expect(en.appOnly.title == "App only — 632 MB")
      #expect(en.everything.title == "Everything — 12.6 GB")
      #expect(en.appOnly.removes == "Removes: Claude mv2 from the Applications folder")
      #expect(en.appOnly.keeps == "Keeps: this app’s sign-in, settings and cache (11.97 GB)")
      #expect(en.footer == "The main Claude and your other apps are not affected.")
    }
  }

  @Test(.english) func editorAndStepsInEnglish() {
    #expect(BuildSummary.stepTitle("copy") == "Copying the app")
    #expect(InstanceEditorText.building("Claude Work", rebuild: false) == "Building “Claude Work”… usually 1–3 minutes")
    #expect(InstanceEditorText.installText.hasSuffix("choose Always Allow."))
    #expect(InstanceEditorViewModel.text(for: EditInstanceError.notVerified(step: "sign"))
      == "The build failed the check at the “Signing” step — nothing was changed")
  }
}
