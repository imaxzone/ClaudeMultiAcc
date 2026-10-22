import Foundation
import Support
import Testing
@testable import InstanceBuilder

/// Representative user messages of the builder in both languages, read from the module's own `.lproj` tables.
@Suite struct LocalizedMessagesTests {
  @Test func theModuleTableHasBothLanguages() {
    #expect(BuilderText.table.availableLanguages == ["en", "ru"])
  }

  @Test func pathRefusalsReadInBothLanguages() {
    let refusal = ClonePathRefusal.appLocation(name: "Claude mv2", path: "~/Desktop/Claude mv2.app")
    Localization.$pinned.withValue("ru") {
      #expect(refusal.userMessage
        == "«Claude mv2»: ~/Desktop/Claude mv2.app — не приложение прямо в папке «Программы» — ничего не изменено")
    }
    Localization.$pinned.withValue("en") {
      #expect(refusal.userMessage
        == "“Claude mv2”: ~/Desktop/Claude mv2.app is not an app directly in the Applications folder — nothing was changed")
      #expect(UserMessage.text(for: refusal) == refusal.userMessage)
    }
  }

  @Test func countsAndSizesFollowTheLanguage() {
    Localization.$pinned.withValue("ru") {
      #expect(BuilderText.format("remove.still-running", "Claude mv2", 30)
        == "«Claude mv2» не закрылся за 30 секунд. Закройте его и попробуйте снова — ничего не удалено.")
      #expect(BuilderText.format("remove.still-running", "Claude mv2", 21).contains("за 21 секунду."))
      #expect(BuilderText.format("remove.still-running", "Claude mv2", 2).contains("за 2 секунды."))
      #expect(RebuildError.preflightFailed(["a", "b", "c"]).userMessage == "Не пройдено проверок: 3")
      #expect(BuilderError.insufficientSpace(availableBytes: 1_200_000_000).userMessage
        == "Мало места на диске: свободно 1,2 ГБ")
    }
    Localization.$pinned.withValue("en") {
      #expect(BuilderText.format("remove.still-running", "Claude mv2", 30)
        == "“Claude mv2” did not quit within 30 seconds. Quit it and try again — nothing was deleted.")
      #expect(BuilderText.format("remove.still-running", "Claude mv2", 1).contains("within 1 second."))
      #expect(RebuildError.preflightFailed(["a"]).userMessage == "1 check failed")
      #expect(RebuildError.preflightFailed(["a", "b", "c"]).userMessage == "3 checks failed")
      #expect(BuilderError.insufficientSpace(availableBytes: 1_200_000_000).userMessage
        == "Not enough disk space: 1.2 GB free")
      #expect(NewInstanceError.nameTooLong(45).message == "No longer than 40 characters, now 45")
      #expect(SigningSetup.userHint.contains("“+ Add”"))
    }
  }
}
