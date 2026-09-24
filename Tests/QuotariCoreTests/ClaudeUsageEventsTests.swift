import Foundation
@testable import QuotariCore
import Testing

struct ClaudeUsageEventsTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
  }()

  private static func day(_ offset: Int) -> Date {
    Date(timeIntervalSince1970: 1_783_478_400 + Double(offset) * 86400)
  }

  private static func range(_ start: Int, _ end: Int) -> DayRange {
    DayRange(start: day(start), end: day(end), calendar: calendar)
  }

  private static func record(day offset: Int, cacheRead: Int) -> LocalTokenRecord {
    LocalTokenRecord(
      day: day(offset),
      model: "claude",
      tokens: TokenTotals(input: 0, cacheRead: cacheRead, cacheWrite: 0, output: 0),
      contextInputTokens: nil,
      sessionID: "session"
    )
  }

  @Test func lastInWindowRowWinsAndOutOfWindowDuplicatesAreIgnoredPerWindow() {
    var events = ClaudeUsageEvents()
    events.append(record: Self.record(day: 5, cacheRead: 10), key: "req")
    events.lineNumber += 1
    events.append(record: Self.record(day: 5, cacheRead: 11), key: "req")
    events.lineNumber += 1
    events.append(record: Self.record(day: 0, cacheRead: 99), key: "req")

    let narrow = ClaudeUsageEvents.resolve(events.events, in: Self.range(1, 10))
    let wide = ClaudeUsageEvents.resolve(events.events, in: Self.range(0, 10))

    #expect(narrow.records.map(\.tokens.cacheRead) == [11])
    #expect(wide.records.map(\.tokens.cacheRead) == [99])
    #expect(events.events.count == 2)
  }

  @Test func unsupportedRowSurvivesOnlyWhenNoLaterRecordSharesItsKey() {
    var unsupportedLast = ClaudeUsageEvents()
    unsupportedLast.append(record: Self.record(day: 3, cacheRead: 10), key: "a")
    unsupportedLast.lineNumber += 1
    unsupportedLast.appendUnsupportedUsage(
      day: Self.day(3), model: "claude", sessionID: "session", key: "a", hasPositiveUsage: true
    )
    var recordLast = ClaudeUsageEvents()
    recordLast.appendUnsupportedUsage(
      day: Self.day(3), model: "claude", sessionID: "session", key: "a", hasPositiveUsage: true
    )
    recordLast.lineNumber += 1
    recordLast.append(record: Self.record(day: 3, cacheRead: 10), key: "a")

    let first = ClaudeUsageEvents.resolve(unsupportedLast.events, in: Self.range(0, 5))
    let second = ClaudeUsageEvents.resolve(recordLast.events, in: Self.range(0, 5))

    #expect(first.records.count == 1)
    #expect(first.unsupportedUsage.count == 1)
    #expect(second.records.count == 1)
    #expect(second.unsupportedUsage.isEmpty)
  }

  @Test func unkeyedRowsAreAllKeptInLineOrder() {
    var events = ClaudeUsageEvents()
    events.append(record: Self.record(day: 2, cacheRead: 1), key: nil)
    events.lineNumber += 1
    events.append(record: Self.record(day: 2, cacheRead: 2), key: nil)
    events.lineNumber += 1
    events.appendUnsupportedUsage(
      day: Self.day(2), model: "claude", sessionID: "session", key: nil, hasPositiveUsage: false
    )

    let resolved = ClaudeUsageEvents.resolve(events.events, in: Self.range(0, 5))

    #expect(resolved.records.map(\.tokens.cacheRead) == [1, 2])
    #expect(resolved.unsupportedUsage.isEmpty)
  }
}
