import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

struct UsageInsightsPresentationTests {
  @Test func periodSelectionSlicesEveryDisplayedMetric() throws {
    let summary = fixture()
    let sevenDays = try #require(UsageInsightsPresentation(
      summary: summary,
      period: .sevenDays
    ))
    let thirtyDays = try #require(UsageInsightsPresentation(
      summary: summary,
      period: .thirtyDays
    ))

    #expect(sevenDays.points.count == 7)
    #expect(thirtyDays.points.count == 30)
    #expect(sevenDays.average == 1)
    #expect(thirtyDays.average == 1)
    #expect(sevenDays.periodValue != thirtyDays.periodValue)
    #expect(sevenDays.insightCells.map(\.kind) == [.topModel, .cache, .sessions])
  }

  @Test func unavailablePricingFallsBackToTrustworthyTokens() throws {
    let summary = fixture(
      spend: .unavailable(.missingPricing),
      coverage: CostEstimateCoverage(
        pricedTokens: 0,
        unpricedTokens: 100,
        unpricedModels: ["future-model"]
      )
    )
    let presentation = try #require(UsageInsightsPresentation(
      summary: summary,
      period: .sevenDays
    ))

    #expect(presentation.metric == .tokens)
    #expect(presentation.coverageIsWarning)
    #expect(presentation.coverageLabel.contains("Pricing unavailable"))
  }

  @Test func unavailableOptionalMetricsAreOmitted() throws {
    let summary = fixture(
      input: .unavailable(.unsupportedTokenFields),
      cacheRead: .available(20),
      sessions: .partial(value: 1, limitation: .unstableSessionIdentity)
    )
    let presentation = try #require(UsageInsightsPresentation(
      summary: summary,
      period: .sevenDays
    ))

    #expect(presentation.insightCells.map(\.kind) == [.topModel])
  }

  @Test func unavailableDailySpendStaysMissingAndDoesNotLowerTheAverage() throws {
    var summary = fixture()
    summary.daily[summary.daily.count - 2].spend = .unavailable(.missingPricing)

    let presentation = try #require(UsageInsightsPresentation(
      summary: summary,
      period: .sevenDays
    ))

    #expect(presentation.points.compactMap(\.value).count == 6)
    #expect(presentation.points[presentation.points.count - 2].value == nil)
    #expect(presentation.average == 1)
  }

  @Test func initialExpansionWaitsForAnEarlierProviderToSettle() {
    let summary = fixture()
    let states: [UsageProvider: UsageInsightsLoadState] = [
      .claude: .loading(cached: nil),
      .codex: .loaded(summary),
    ]

    #expect(DashboardInsightsExpansion.initialProvider(
      enabledProviders: [.claude, .codex],
      states: states,
      isRefreshing: false
    ) == nil)
  }

  @Test func initialExpansionUsesTheFirstEligibleProviderInProviderOrder() {
    let summary = fixture()
    let states: [UsageProvider: UsageInsightsLoadState] = [
      .claude: .failed(previous: nil, message: "Unavailable"),
      .codex: .loaded(summary),
    ]

    #expect(DashboardInsightsExpansion.initialProvider(
      enabledProviders: [.claude, .codex],
      states: states,
      isRefreshing: false
    ) == .codex)
  }

  @Test func existingCostWinsWhileStructuredInsightsHaveNoSummary() {
    #expect(ProviderUsageSectionContent.resolve(
      state: .loading(cached: nil),
      hasCost: true
    ) == .legacyCost)
    #expect(ProviderUsageSectionContent.resolve(
      state: .failed(previous: nil, message: "Unavailable"),
      hasCost: true
    ) == .legacyCost)
    #expect(ProviderUsageSectionContent.resolve(
      state: .loading(cached: nil),
      hasCost: false
    ) == .insights)
  }

  @Test func collapsedAccessibilityValueIncludesBothVisibleMetrics() throws {
    let presentation = try #require(UsageInsightsPresentation(
      summary: fixture(),
      period: .sevenDays
    ))

    let value = presentation.compactAccessibilityValue

    #expect(value.contains(L10n.string("Today")))
    #expect(value.contains(presentation.todayValue))
    #expect(value.contains(presentation.periodLabel))
    #expect(value.contains(presentation.periodValue))
  }

  private func fixture(
    spend: UsageMetric<Double> = .available(1),
    coverage: CostEstimateCoverage = CostEstimateCoverage(
      pricedTokens: 100,
      unpricedTokens: 0
    ),
    input: UsageMetric<Int> = .available(50),
    cacheRead: UsageMetric<Int> = .available(20),
    sessions: UsageMetric<Int> = .available(1)
  ) -> UsageInsightsSummary {
    let calendar = Calendar(identifier: .gregorian)
    let today = Date(timeIntervalSince1970: 1_783_478_400)
    let tokens = UsageTokenBreakdown(
      input: input,
      output: .available(20),
      cacheRead: cacheRead,
      cacheWrite: .available(10),
      total: .available(100)
    )
    let daily = (0 ..< 30).map { offset in
      let date = calendar.date(byAdding: .day, value: offset - 29, to: today) ?? today
      return DailyUsageInsight(
        date: date,
        spend: spend,
        tokens: tokens,
        sessionCount: sessions,
        models: [
          ModelUsageInsight(
            modelID: "gpt-5",
            spend: spend,
            tokens: tokens,
            pricingCoverage: coverage
          ),
        ],
        pricingCoverage: coverage
      )
    }
    return UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(provider: .codex, accountScopeID: "test"),
      generatedAt: today,
      source: .localCodexLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local Codex logs",
      daily: daily
    )
  }
}
