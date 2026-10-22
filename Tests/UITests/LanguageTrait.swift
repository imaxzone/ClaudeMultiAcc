import Support
import Testing

/// Runs a test, or every test of a suite, with the UI strings in one language (`Localization.pinned`), whatever the
/// machine's languages: `@Suite(.russian)` for tests that read the Russian wording.
struct LanguageTrait: TestTrait, SuiteTrait, TestScoping {
  let language: String

  var isRecursive: Bool { true }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    try await Localization.$pinned.withValue(language) { try await function() }
  }
}

extension Trait where Self == LanguageTrait {
  static func language(_ language: String) -> Self { LanguageTrait(language: language) }
  static var russian: Self { .language("ru") }
  static var english: Self { .language("en") }
}
