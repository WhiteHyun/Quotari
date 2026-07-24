import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreInsightsStateTests {
  @Test func completedCostRefreshPublishesTheStructuredInsightsCache() throws {
    let summary = fixture()
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      costEstimator: InsightsStateEstimator(summary: summary),
      startsAutomatically: false
    )
    store.beginUsageInsightsRefresh(provider: .codex, cached: nil)

    try store.finishUsageInsightsRefresh(
      .updated(#require(summary.costSummary)),
      provider: .codex,
      account: nil,
      credentialTransition: nil,
      now: summary.generatedAt
    )

    #expect(store.usageInsightsState(for: .codex) == .loaded(summary))
  }

  @Test func unavailableRefreshKeepsTheLastStructuredInsights() {
    let summary = fixture()
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      startsAutomatically: false
    )
    store.beginUsageInsightsRefresh(provider: .codex, cached: summary)

    store.finishUsageInsightsRefresh(
      .unavailable,
      provider: .codex,
      account: nil,
      credentialTransition: nil,
      now: summary.generatedAt
    )

    guard case let .failed(previous, _) = store.usageInsightsState(for: .codex) else {
      Issue.record("Expected a failed state that retains the previous insights")
      return
    }
    #expect(previous == summary)
  }

  @Test func confirmedEmptyRefreshClearsTheStructuredInsights() {
    let summary = fixture()
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      startsAutomatically: false
    )
    store.beginUsageInsightsRefresh(provider: .codex, cached: summary)

    store.finishUsageInsightsRefresh(
      .confirmedEmpty,
      provider: .codex,
      account: nil,
      credentialTransition: nil,
      now: summary.generatedAt
    )

    #expect(store.usageInsightsState(for: .codex) == .empty(.noLocalUsage))
  }

  private func fixture() -> UsageInsightsSummary {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let tokens = UsageTokenBreakdown(
      input: .available(50),
      output: .available(20),
      cacheRead: .available(20),
      cacheWrite: .available(10),
      total: .available(100)
    )
    let coverage = CostEstimateCoverage(pricedTokens: 100, unpricedTokens: 0)
    return UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(provider: .codex, accountScopeID: "test"),
      generatedAt: now,
      source: .localCodexLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local Codex logs",
      daily: (0 ..< 30).map { offset in
        DailyUsageInsight(
          date: now.addingTimeInterval(TimeInterval(offset - 29) * 86400),
          spend: .available(1),
          tokens: tokens,
          sessionCount: .available(1),
          models: [],
          pricingCoverage: coverage
        )
      }
    )
  }
}

private struct InsightsStateEstimator: UsageCostEstimating {
  let summary: UsageInsightsSummary

  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary? {
    summary
  }

  func costSummary(
    provider: UsageProvider,
    now: Date,
    historyDays: Int
  ) async -> CostSummary? {
    summary.costSummary
  }
}
