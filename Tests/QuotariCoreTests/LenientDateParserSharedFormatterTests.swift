import Foundation
@testable import QuotariCore
import Testing

struct LenientDateParserSharedFormatterTests {
  private static let samples: [(String, TimeInterval)] = [
    ("2026-07-28T07:00:00.123Z", 1_785_222_000.123),
    ("2026-07-28T07:00:00Z", 1_785_222_000),
    ("2026-07-28T07:00:00z", 1_785_222_000),
    ("2026-07-28T07:00:00.123456+00:00", 1_785_222_000.123),
    ("2026-07-28", 1_785_196_800),
  ]

  @Test func supportedShapesParseToTheSameInstant() throws {
    for (string, expected) in Self.samples {
      let date = try #require(LenientDateParser.parse(string), "\(string)")
      #expect(abs(date.timeIntervalSince1970 - expected) < 0.001, "\(string)")
    }
    #expect(LenientDateParser.parse("not a date") == nil)
  }

  /// The formatters are shared across scans running on concurrent tasks.
  @Test func sharedFormattersParseConsistentlyFromConcurrentTasks() async {
    let results = await withTaskGroup(of: Bool.self) { group in
      for index in 0 ..< 64 {
        group.addTask {
          let (string, expected) = Self.samples[index % Self.samples.count]
          return (0 ..< 200).allSatisfy { _ in
            guard let date = LenientDateParser.parse(string) else { return false }
            return abs(date.timeIntervalSince1970 - expected) < 0.001
          }
        }
      }
      return await group.reduce(into: [Bool]()) { $0.append($1) }
    }

    #expect(results.count == 64)
    #expect(!results.contains(false))
  }
}
