import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreDailyUsageArchiveTests {
  private let now = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 / 86400 * 86400))

  @Test func theDashboardKeepsADayAfterItsLogsAreDeletedAndExportsIt() throws {
    let estimator = ChangingInsightsEstimator(summary: summary(tokens: [400, 100]))
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      costEstimator: estimator,
      startsAutomatically: false
    )
    _ = store.cachedUsageInsights(provider: .codex, account: nil, credentialTransition: nil, now: now)

    // Codex's logs for the first day are gone.
    estimator.summary = summary(tokens: [0, 100])
    let restored = try #require(
      store.cachedUsageInsights(provider: .codex, account: nil, credentialTransition: nil, now: now).summary
    )
    store.usageInsightsStates[.codex] = .loaded(restored)

    #expect(restored.daily.map(\.tokens.total.value) == [400, 100])
    let export = try #require(store.usageExport(for: .codex))
    #expect(export.days.map(\.tokens.total.value) == [400, 100])
    #expect(export.source == .localCodexLogs)
  }

  private func summary(tokens: [Int]) -> UsageInsightsSummary {
    UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(provider: .codex, accountScopeID: "archive"),
      generatedAt: now,
      source: .localCodexLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local Codex logs",
      daily: tokens.enumerated().map { offset, total in
        DailyUsageInsight(
          date: now.addingTimeInterval(TimeInterval(offset - tokens.count + 1) * 86400),
          spend: .available(Double(total) / 100),
          tokens: UsageTokenBreakdown(
            input: .available(total),
            output: .available(0),
            cacheRead: .available(0),
            cacheWrite: .available(0),
            total: .available(total)
          ),
          sessionCount: .available(total > 0 ? 1 : 0),
          models: [],
          pricingCoverage: CostEstimateCoverage(pricedTokens: total, unpricedTokens: 0)
        )
      }
    )
  }
}

private final class ChangingInsightsEstimator: UsageCostEstimating, @unchecked Sendable {
  var summary: UsageInsightsSummary

  init(summary: UsageInsightsSummary) {
    self.summary = summary
  }

  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary? {
    summary
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}
