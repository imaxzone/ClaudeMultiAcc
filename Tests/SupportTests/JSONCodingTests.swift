import Foundation
import Testing
@testable import Support

@Suite struct JSONCodingTests {
  struct Sample: Codable, Equatable { let b: Int; let a: Date }

  @Test func encodesSortedPrettyISO8601() throws {
    let sample = Sample(b: 1, a: Date(timeIntervalSince1970: 0))
    let text = String(decoding: try JSONCoding.encoder.encode(sample), as: UTF8.self)
    #expect(text.contains("\"1970-01-01T00:00:00Z\""))
    let aIndex = try #require(text.range(of: "\"a\""))
    let bIndex = try #require(text.range(of: "\"b\""))
    #expect(aIndex.lowerBound < bIndex.lowerBound)
    #expect(text.contains("\n"))
    #expect(try JSONCoding.decoder.decode(Sample.self, from: Data(text.utf8)) == sample)
  }
}
