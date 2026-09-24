import Foundation
@testable import QuotariCore
import Testing

struct InternetTimestampTests {
  /// The formatters `LenientDateParser` used before the fast path, in order.
  private nonisolated(unsafe) static let referenceFormatters: [ISO8601DateFormatter] = [
    [.withInternetDateTime, .withFractionalSeconds],
    [.withInternetDateTime],
  ].map { (options: ISO8601DateFormatter.Options) in
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = options
    return formatter
  }

  private static func reference(_ string: String) -> Date? {
    referenceFormatters.lazy.compactMap { $0.date(from: string) }.first
  }

  @Test func fastPathMatchesTheFormattersBitForBitOnRandomTimestamps() throws {
    var generator = SystemRandomNumberGenerator()
    var compared = 0
    for _ in 0 ..< 20000 {
      let year = Int.random(in: 1970 ... 2100, using: &generator)
      let month = Int.random(in: 1 ... 12, using: &generator)
      let day = Int.random(in: 1 ... 31, using: &generator)
      var text = String(
        format: "%04d-%02d-%02dT%02d:%02d:%02d",
        year,
        month,
        day,
        Int.random(in: 0 ... 23, using: &generator),
        Int.random(in: 0 ... 59, using: &generator),
        Int.random(in: 0 ... 59, using: &generator)
      )
      let fractionDigits = Int.random(in: 0 ... 9, using: &generator)
      if fractionDigits > 0 {
        text += "." + (0 ..< fractionDigits).map { _ in String(Int.random(in: 0 ... 9, using: &generator)) }.joined()
      }
      switch Int.random(in: 0 ... 2, using: &generator) {
      case 0: text += "Z"
      case 1: try text += String(
          format: "+%02d:%02d",
          Int.random(in: 0 ... 14, using: &generator),
          #require([0, 30, 45].randomElement())
        )
      default: try text += String(
          format: "-%02d:%02d",
          Int.random(in: 0 ... 12, using: &generator),
          #require([0, 30].randomElement())
        )
      }

      guard let fast = InternetTimestamp.parse(text) else { continue }
      compared += 1
      #expect(fast.timeIntervalSince1970 == Self.reference(text)?.timeIntervalSince1970, "\(text)")
    }
    #expect(compared > 15000)
  }

  @Test(arguments: [
    "2026-02-30T00:00:00Z",
    "2026-13-01T00:00:00Z",
    "2026-07-28T24:00:00Z",
    "2026-07-28T07:00:60Z",
    "2026-07-28T07:00:00",
    "2026-07-28 07:00:00Z",
    "2026-07-28T07:00:00.Z",
    "2026-07-28T07:00:00z",
    "2026-07-28T07:00:00+0900",
    "2026-07-28",
    "not-a-timestamp-at-all",
  ])
  func nonCanonicalInputIsLeftToTheFormatters(text: String) {
    #expect(InternetTimestamp.parse(text) == nil)
  }

  @Test func leapDayAndOffsetsResolveToUTC() throws {
    let leap = try #require(InternetTimestamp.parse("2028-02-29T12:00:00Z"))
    let offset = try #require(InternetTimestamp.parse("2026-07-28T16:00:00.5+09:00"))
    let micros = try #require(InternetTimestamp.parse("2026-07-28T07:00:00.123456Z"))

    #expect(leap.timeIntervalSince1970 == Self.reference("2028-02-29T12:00:00Z")?.timeIntervalSince1970)
    #expect(offset.timeIntervalSince1970 == 1_785_222_000.5)
    #expect(micros.timeIntervalSince1970 == Self.reference("2026-07-28T07:00:00.123456Z")?.timeIntervalSince1970)
  }
}
