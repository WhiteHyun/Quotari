import Foundation
@testable import QuotariCore
import Testing

struct UsagePaceForecastTests {
  private let day: TimeInterval = 86400
  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  @Test func aFasterRecentRateBringsTheRunOutForward() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    // 30% used after 3 of 7 days: 10% a day on average.
    let window = RateWindow(
      kind: .weekly,
      usedPercent: 30,
      resetsAt: now.addingTimeInterval(4 * day),
      duration: 7 * day
    )

    let average = try #require(UsagePace.compute(window: window, now: now))
    let recent = try #require(UsagePace.compute(window: window, now: now, recentBurnRate: 20 / day))

    #expect(average.runsOutIn == nil)
    #expect(recent.runsOutIn == 3.5 * day)
  }

  @Test func weekdayPaceIgnoresTheWeekend() throws {
    let monday = Date(timeIntervalSince1970: 1_799_625_600) // 2027-01-11 00:00 UTC
    let saturdayNoon = monday.addingTimeInterval(5.5 * day)
    let window = RateWindow(
      kind: .weekly,
      usedPercent: 80,
      resetsAt: monday.addingTimeInterval(7 * day),
      duration: 7 * day
    )

    let wallClock = try #require(UsagePace.compute(window: window, now: saturdayNoon))
    let weekdays = try #require(UsagePace.compute(
      window: window,
      now: saturdayNoon,
      countsWeekdaysOnly: true,
      calendar: utc
    ))

    #expect(wallClock.isDeficit)
    // All five weekdays have passed, so 80% used is 20% in reserve.
    #expect(abs(weekdays.deltaPercent - -20) < 1e-9)
  }
}
