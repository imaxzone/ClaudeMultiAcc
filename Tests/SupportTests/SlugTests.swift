import Foundation
import Testing
@testable import Support

@Suite struct SlugTests {
  @Test(arguments: ["main", "second", "a", "work-2", "0abc", String(repeating: "a", count: 32)])
  func acceptsValid(_ raw: String) throws {
    let slug = try Slug(raw)
    #expect(slug.raw == raw)
    #expect(slug.description == raw)
  }

  @Test func rejectsUppercase() {
    #expect(throws: SlugError.invalid("Main")) { try Slug("Main") }
  }

  @Test(arguments: ["", "-lead", "has space", "dots.no", "ünï", "a/b", String(repeating: "a", count: 33)])
  func rejectsInvalid(_ raw: String) {
    #expect(throws: SlugError.invalid(raw)) { try Slug(raw) }
  }

  @Test func codableRoundTripAsPlainString() throws {
    let data = try JSONEncoder().encode([try Slug("work")])
    #expect(String(decoding: data, as: UTF8.self) == #"["work"]"#)
    #expect(try JSONDecoder().decode([Slug].self, from: data) == [try Slug("work")])
  }

  @Test func decodingInvalidSlugFails() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([Slug].self, from: Data(#"["BAD"]"#.utf8))
    }
  }
}
