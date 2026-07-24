import Foundation
@testable import QuotariCore

struct SnapshotCostEstimator: UsageCostEstimating {
  static let day = Date(timeIntervalSince1970: 1_783_478_400)

  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary? {
    Self.insights(provider: provider, now: now, historyDays: historyDays)
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    Self.insights(provider: provider, now: now, historyDays: historyDays).costSummary
  }

  private static func insights(
    provider: UsageProvider,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary {
    let calendar = Calendar(identifier: .gregorian)
    let today = calendar.startOfDay(for: now)
    let daily = (0 ..< historyDays).map { offset in
      dailyInsight(
        provider: provider,
        date: calendar.date(
          byAdding: .day,
          value: offset - (historyDays - 1),
          to: today
        ) ?? today,
        scale: offset % 7 + 1
      )
    }
    return UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(
        provider: provider,
        accountScopeID: "snapshot-\(provider.rawValue)"
      ),
      generatedAt: now,
      source: provider == .codex ? .localCodexLogs : .localClaudeCacheLogs,
      accountScope: .exact,
      sourceDescription: provider == .codex
        ? "Estimated from local Codex logs"
        : "Estimated from local Claude cache logs",
      daily: daily
    )
  }

  private static func dailyInsight(
    provider: UsageProvider,
    date: Date,
    scale: Int
  ) -> DailyUsageInsight {
    let model = provider == .codex ? "gpt-5.3-codex" : "claude-opus-4-1"
    let tokens = tokenBreakdown(scale: scale)
    let spend: UsageMetric<Double> = provider == .codex
      ? .available(Double(scale) * 0.72)
      : .partial(value: Double(scale) * 0.54, limitation: .unsupportedTokenFields)
    let coverage = CostEstimateCoverage(
      pricedTokens: 260_000 * scale,
      unpricedTokens: provider == .claude ? 15000 : 0,
      unpricedModels: provider == .claude ? ["claude-future"] : []
    )
    return DailyUsageInsight(
      date: date,
      spend: spend,
      tokens: tokens,
      sessionCount: .available(scale),
      models: [
        ModelUsageInsight(
          modelID: model,
          spend: spend,
          tokens: tokens,
          pricingCoverage: coverage
        ),
      ],
      pricingCoverage: coverage
    )
  }

  private static func tokenBreakdown(scale: Int) -> UsageTokenBreakdown {
    UsageTokenBreakdown(
      input: .available(120_000 * scale),
      output: .available(40000 * scale),
      cacheRead: .available(90000 * scale),
      cacheWrite: .available(10000 * scale),
      total: .available(260_000 * scale)
    )
  }
}
