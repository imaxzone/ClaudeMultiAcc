import Foundation
import Testing
@testable import Support

/// The two fields of the «Изменить…» / «Добавить» window: the app's name and the label on its icon.
@Suite(.russian) struct InstanceDraftTests {
  private func four() throws -> [Instance] {
    let root = try makeTempDir()
    struct File: Decodable { let instances: [Instance] }
    return try JSONCoding.decoder.decode(File.self, from: Data(try fixtureText("instances-four.json", root: root).utf8)).instances
  }

  @Test func bothFieldsAreTrimmed() {
    let draft = InstanceDraft(name: "  Claude mv2 \n", badge: " mv2 ")
    #expect(draft.name == "Claude mv2" && draft.badge == "mv2")
  }

  @Test func aFreshNameAndAShortLabelPass() throws {
    #expect(InstanceDraft(name: "Claude mv2", badge: "mv2").problems(existing: try four()).isEmpty)
    #expect(InstanceDraft(name: "Работа", badge: "Раб").problems(existing: try four()).isEmpty)
    #expect(InstanceDraft(name: "Claude 👨‍👩‍👧", badge: "👨‍👩‍👧").problems(existing: try four()).isEmpty)
  }

  @Test(arguments: [
    ("", InstanceDraftProblem.emptyName), ("   ", .emptyName), ("Claude\tmv2", .nameControlCharacters),
    ("Claude\u{0007}", .nameControlCharacters), ("Claude \u{202E}gpj", .nameControlCharacters),
    ("Claude/mv2", .nameNotAFileName), ("Claude:mv2", .nameNotAFileName), (".hidden", .nameNotAFileName),
    (String(repeating: "n", count: 41), .nameTooLong(41)), ("claude work", .nameTaken("Claude Work")),
    ("Claude", .nameTaken("Claude")), ("CLAUDE (ALT CLI)", .nameTaken("Claude (alt CLI)")),
  ])
  func nameRules(name: String, problem: InstanceDraftProblem) throws {
    #expect(InstanceDraft(name: name, badge: "ok").problems(existing: try four()) == [problem])
  }

  @Test(arguments: [
    ("", InstanceDraftProblem.emptyBadge), ("   ", .emptyBadge), ("Работа", .badgeTooLong(6)), ("ab cd", .badgeTooLong(5)),
    ("a\u{0007}", .badgeControlCharacters), ("a\nb", .badgeControlCharacters),
  ])
  func badgeRules(badge: String, problem: InstanceDraftProblem) throws {
    #expect(InstanceDraft(name: "Claude mv2", badge: badge).problems(existing: try four()) == [problem])
  }

  @Test func labelsOfOneToFourCharactersPass() throws {
    for badge in ["W", "mv2", "mv22", "5x a", "日本"] {
      #expect(InstanceDraft(name: "Claude mv2", badge: badge).problems(existing: try four()).isEmpty, "\(badge)")
    }
  }

  /// The app being edited may keep its name (in any letter case); the others still count.
  @Test func editingKeepsItsOwnName() throws {
    let existing = try four()
    let work = try Slug("work")
    #expect(InstanceDraft(name: "Claude Work", badge: "W").problems(existing: existing, editing: work).isEmpty)
    #expect(InstanceDraft(name: "CLAUDE WORK", badge: "W").problems(existing: existing, editing: work).isEmpty)
    #expect(InstanceDraft(name: "Claude 2nd", badge: "W").problems(existing: existing, editing: work)
      == [.nameTaken("Claude 2nd")])
  }

  /// One message per field at most, name first.
  @Test func atMostOneProblemPerFieldInFieldOrder() throws {
    let problems = InstanceDraft(name: "", badge: "").problems(existing: try four())
    #expect(problems == [.emptyName, .emptyBadge])
    #expect(problems.map(\.field) == [.name, .badge])
  }

  @Test func problemsHaveRussianMessagesAndEnglishDescriptions() {
    let all: [InstanceDraftProblem] = [
      .emptyName, .nameTooLong(41), .nameControlCharacters, .nameNotAFileName, .nameTaken("Claude Work"), .emptyBadge,
      .badgeTooLong(6), .badgeControlCharacters,
    ]
    for problem in all {
      #expect(problem.message.range(of: "[А-Яа-я]", options: .regularExpression) != nil, "\(problem)")
      #expect(problem.description.range(of: "[А-Яа-я]", options: .regularExpression) == nil, "\(problem)")
    }
    #expect(InstanceDraftProblem.nameTaken("Claude Work").message == "«Claude Work» уже есть — выберите другое название")
    #expect(InstanceDraftProblem.badgeTooLong(6).message == "Не больше 4 знаков, сейчас 6")
  }
}

@Suite(.russian) struct InstanceDraftNameTests {
  @Test func sameNameIgnoresLetterCaseNormalizationAndSpaces() {
    #expect(InstanceDraft.isSameName("Claude Work", " claude WORK "))
    #expect(InstanceDraft.isSameName("Café", "Cafe\u{301}"))
    #expect(!InstanceDraft.isSameName("Claude Work", "Claude Job"))
  }
}
