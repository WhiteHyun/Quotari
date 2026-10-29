import Foundation
import QuotariCore

extension UsageStore {
  /// Local insights for an account the dashboard isn't showing. Only local
  /// logs are read; nil when none can be attributed to the account.
  func analyticsInsights(provider: UsageProvider, account: ProviderAccount) async -> UsageInsightsSummary? {
    let estimator = costEstimator
    guard let summary = await estimator.insights(provider: provider, account: account, now: Date(), historyDays: 30)
    else { return nil }
    return dailyUsageArchive.keep(summary)
  }

  /// Every recorded day for the summary's scope, ready to save.
  func usageExport(for summary: UsageInsightsSummary) -> UsageExport {
    UsageExport(
      provider: summary.scopeKey.provider,
      source: summary.source,
      accountScope: summary.accountScope,
      days: dailyUsageArchive.days(for: summary.scopeKey)
    )
  }
}
