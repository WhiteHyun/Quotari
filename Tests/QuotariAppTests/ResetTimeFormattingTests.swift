import Foundation
@testable import Quotari
import Testing

struct ResetTimeFormattingTests {
  /// Tuesday 2026-11-03 10:00 UTC.
  private let now = Date(timeIntervalSince1970: 1_793_700_000)
  private let english = Locale(identifier: "en_US@hours=h23")
  private let korean = Locale(identifier: "ko_KR@hours=h23")

  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
  }

  private func clock(_ date: Date, _ locale: Locale) -> String? {
    LocalizedUsageFormatter.resetPhrase(to: date, style: .clockTime, now: now, locale: locale, calendar: calendar)
  }

  @Test func clockTimeGetsCoarserWithDistance() {
    #expect(clock(date(3, 15, 30), english) == "15:30")
    #expect(clock(date(4, 1, 30), english) == "tomorrow 01:30")
    #expect(clock(date(6, 9, 0), english) == "Fri 09:00")
    #expect(clock(date(9, 9, 0), english) == "Mon 09:00")
    #expect(clock(date(10, 9, 0), english) == "Nov 10")
    #expect(clock(date(12, 9, 0), english) == "Nov 12")
  }

  @Test func clockTimeIsLocalized() {
    #expect(clock(date(4, 1, 30), korean) == "내일 01:30")
    #expect(clock(date(6, 9, 0), korean) == "금 09:00")
    #expect(clock(date(12, 9, 0), korean) == "11월 12일")
  }

  @Test func clockTimeFollowsTheHourCycle() {
    let twelveHour = Locale(identifier: "en_US@hours=h12")
    let phrase = clock(date(3, 15, 30), twelveHour)
    #expect(phrase?.contains("3:30") == true)
    #expect(phrase?.contains("PM") == true)
  }

  @Test func eachStyleFillsTheResetsLine() {
    let reset = date(3, 12, 13)
    func line(_ style: ResetTimeStyle, _ locale: Locale) -> String? {
      LocalizedUsageFormatter.resetPhrase(to: reset, style: style, now: now, locale: locale, calendar: calendar)
        .map { L10n.string("Resets \($0)", locale: locale) }
    }
    #expect(line(.countdown, english) == "Resets in 2h 13m")
    #expect(line(.clockTime, english) == "Resets 12:13")
    #expect(line(.both, english) == "Resets in 2h 13m · 12:13")
    #expect(line(.both, korean) == "2시간 13분 후 · 12:13에 초기화")
  }

  @Test func aPassedResetReadsNowInEveryStyle() {
    for style in ResetTimeStyle.allCases {
      #expect(
        LocalizedUsageFormatter.resetPhrase(
          to: date(3, 9, 0),
          style: style,
          now: now,
          locale: english,
          calendar: calendar
        )
          == "now"
      )
    }
    #expect(LocalizedUsageFormatter.resetPhrase(to: nil, style: .both, now: now, locale: english) == nil)
  }
}

@MainActor
struct ResetTimeStylePreferenceTests {
  @Test func persistsAndRestoresOnNextLaunch() throws {
    let suiteName = "quotari-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    func makeStore() -> UsageStore {
      UsageStore.isolatedForTesting(
        providers: ProviderFixtures.descriptors,
        defaults: defaults,
        startsAutomatically: false
      )
    }

    let store = makeStore()
    #expect(store.resetTimeStyle == .countdown)
    store.resetTimeStyle = .both

    #expect(defaults.string(forKey: UsageStore.resetTimeStyleDefaultsKey) == "both")
    #expect(makeStore().resetTimeStyle == .both)
  }
}
