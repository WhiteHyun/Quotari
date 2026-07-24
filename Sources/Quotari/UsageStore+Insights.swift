import Foundation
import QuotariCore

extension UsageStore {
  func usageInsightsState(for provider: UsageProvider) -> UsageInsightsLoadState {
    usageInsightsStates[provider] ?? .idle
  }

  func cachedUsageInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date
  ) -> UsageInsightsSummary? {
    costEstimator.cachedInsights(
      provider: provider,
      account: account,
      credentialTransition: credentialTransition,
      now: now,
      historyDays: 30
    )
  }

  func beginUsageInsightsRefresh(
    provider: UsageProvider,
    cached: UsageInsightsSummary?
  ) {
    usageInsightsStates[provider] = .loading(
      cached: cached ?? usageInsightsState(for: provider).summary
    )
  }

  func finishUsageInsightsRefresh(
    _ outcome: UsageCostRefreshOutcome,
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date
  ) {
    let previous = usageInsightsState(for: provider).summary
    switch outcome {
    case .updated:
      if let summary = cachedUsageInsights(
        provider: provider,
        account: account,
        credentialTransition: credentialTransition,
        now: now
      ) {
        usageInsightsStates[provider] = .loaded(summary)
      } else {
        usageInsightsStates[provider] = .failed(
          previous: previous,
          message: "Local insights refresh failed"
        )
      }
    case .confirmedEmpty:
      usageInsightsStates[provider] = .empty(.noLocalUsage)
    case .unavailable:
      usageInsightsStates[provider] = .failed(
        previous: previous,
        message: "Local insights refresh failed"
      )
    }
  }
}
