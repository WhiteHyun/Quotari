import Foundation
@testable import Quotari
import QuotariCore
import Testing

struct MenuBarTodayCostTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
  private let english = Locale(identifier: "en_US")
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  @Test func exactSpendShowsTheAmount() {
    #expect(display(.loaded(summary(today: .available(3.84)))) == "$3.84")
  }

  @Test func partiallyPricedSpendIsMarkedAsAnEstimate() {
    #expect(display(.loaded(summary(today: .partial(value: 3.84, limitation: .missingPricing)))) == "≈$3.84")
  }

  @Test func sharedCacheScopeIsAnEstimateThatIsNotAccountSpecific() {
    let state = UsageInsightsLoadState.loaded(summary(today: .available(3.84), accountScope: .sharedLocalCache))

    #expect(display(state) == "≈$3.84")
    let cost = MenuBarCostDisplay.current(
      MenuBarCostDisplay.resolve(state, now: now, calendar: calendar),
      remembered: nil
    )
    #expect(cost?.isAccountSpecific == false)
  }

  @Test func yesterdaysSummaryIsUnavailableAfterMidnight() {
    #expect(display(.loaded(summary(today: .available(3.84), daysAgo: 1))) == nil)
  }

  @Test func unsupportedTokenFieldsKeepTheLastValueForTheSameScopeAndDay() throws {
    let remembered = try #require(MenuBarCostDisplay.current(
      MenuBarCostDisplay.resolve(.loaded(summary(today: .available(2.5))), now: now, calendar: calendar),
      remembered: nil
    ))
    let unsupported = UsageMetric<Double>.unavailable(.unsupportedTokenFields)

    #expect(display(.loaded(summary(today: unsupported)), remembered: remembered) == "$2.50")
    #expect(display(.loaded(summary(today: unsupported, scopeID: "personal")), remembered: remembered) == nil)
  }

  @Test func aScannedDayWithoutActivityShowsZero() {
    #expect(display(.loaded(summary(today: .available(0)))) == "$0.00")
  }

  @Test func emptyInsightsShowNoValue() {
    // An empty state can't tell missing logs from a quiet month, so it never claims $0.00.
    #expect(display(.empty(.noLocalUsage)) == nil)
  }

  @Test func aFailedRefreshKeepsTheSameDayValue() {
    let state = UsageInsightsLoadState.failed(previous: summary(today: .available(3.84)), message: "read failed")

    #expect(display(state) == "$3.84")
  }

  @Test func unpricedTodayShowsNoValue() {
    #expect(display(.loaded(summary(today: .unavailable(.missingPricing)))) == nil)
  }

  @Test func accessibilityNamesProviderValueCoverageAndFreshness() throws {
    let exact = try #require(cost(.loaded(summary(today: .available(3.84)))))
    let shared = try #require(cost(.loaded(summary(
      today: .partial(value: 3.84, limitation: .missingPricing),
      accountScope: .sharedLocalCache
    ))))

    #expect(MenuBarCostDisplay.accessibilityLabel(providerName: "Codex", cost: exact, now: now, locale: english)
      == "Quotari, Codex cost today $3.84, updated 5m ago")
    #expect(MenuBarCostDisplay.accessibilityLabel(providerName: "Codex", cost: shared, now: now, locale: english)
      == "Quotari, Codex cost today $3.84, estimate, not account-specific, updated 5m ago")
  }

  @Test func accessibilityExplainsMissingSourceOrValue() {
    #expect(MenuBarCostDisplay.accessibilityLabel(providerName: nil, cost: nil, now: now, locale: english)
      == "Quotari, no cost source selected")
    #expect(MenuBarCostDisplay.accessibilityLabel(providerName: "Codex", cost: nil, now: now, locale: english)
      == "Quotari, Codex cost today unavailable")
  }

  @Test func accessibilityIsLocalizedInKorean() throws {
    let korean = Locale(identifier: "ko")
    let shared = try #require(cost(.loaded(summary(today: .available(3.84), accountScope: .sharedLocalCache))))

    let label = MenuBarCostDisplay.accessibilityLabel(providerName: "Codex", cost: shared, now: now, locale: korean)

    #expect(label.hasPrefix("Quotari, Codex 오늘 비용 "))
    #expect(label.contains("추정치, 계정별 값 아님"))
    #expect(MenuBarCostDisplay.accessibilityLabel(providerName: nil, cost: nil, now: now, locale: korean)
      == "Quotari, 비용 기준이 선택되지 않음")
  }

  // MARK: - Helpers

  private func cost(_ state: UsageInsightsLoadState) -> TodayCost? {
    MenuBarCostDisplay.current(MenuBarCostDisplay.resolve(state, now: now, calendar: calendar), remembered: nil)
  }

  private func display(_ state: UsageInsightsLoadState, remembered: TodayCost? = nil) -> String? {
    let resolution = MenuBarCostDisplay.resolve(state, now: now, calendar: calendar)
    return MenuBarCostDisplay.current(resolution, remembered: remembered).map {
      MenuBarCostDisplay.text($0, locale: english)
    }
  }

  private func summary(
    today: UsageMetric<Double>,
    accountScope: UsageInsightsAccountScope = .exact,
    scopeID: String = "work",
    daysAgo: Int = 0
  ) -> UsageInsightsSummary {
    let todayStart = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(-daysAgo) * 86400)
    let tokens = UsageTokenBreakdown(
      input: .available(1), output: .available(1), cacheRead: .available(0),
      cacheWrite: .available(0), total: .available(2)
    )
    let day = { (date: Date, spend: UsageMetric<Double>) in
      DailyUsageInsight(
        date: date, spend: spend, tokens: tokens, sessionCount: .available(1), models: [],
        pricingCoverage: CostEstimateCoverage(pricedTokens: 2, unpricedTokens: 0)
      )
    }
    return UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(provider: .codex, accountScopeID: scopeID),
      generatedAt: now.addingTimeInterval(-300),
      source: .localCodexLogs,
      accountScope: accountScope,
      sourceDescription: "Estimated from local Codex logs",
      daily: [day(todayStart.addingTimeInterval(-86400), .available(2)), day(todayStart, today)]
    )
  }
}
