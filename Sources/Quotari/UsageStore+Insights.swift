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
    cached: UsageInsightsSummary?,
    now: Date
  ) {
    let candidate = cached ?? usageInsightsState(for: provider).summary
    let current = candidate.flatMap { $0.matchesCalendarWindow(at: now) ? $0 : nil }
    usageInsightsStates[provider] = .loading(
      cached: current
    )
  }

  func finishUsageInsightsRefresh(
    _ outcome: UsageCostRefreshOutcome,
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date
  ) {
    let previous = usageInsightsState(for: provider).currentSummary(at: now)
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
