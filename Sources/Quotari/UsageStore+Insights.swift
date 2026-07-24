import Foundation
import QuotariCore

enum CachedUsageInsights {
  case loaded(UsageInsightsSummary)
  case empty
  case missing

  var summary: UsageInsightsSummary? {
    guard case let .loaded(summary) = self else { return nil }
    return summary
  }

  var loadState: UsageInsightsLoadState? {
    switch self {
    case let .loaded(summary):
      .loaded(summary)
    case .empty:
      .empty(.noLocalUsage)
    case .missing:
      nil
    }
  }
}

extension UsageStore {
  func usageInsightsState(for provider: UsageProvider) -> UsageInsightsLoadState {
    usageInsightsStates[provider] ?? .idle
  }

  func cachedUsageInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date
  ) -> CachedUsageInsights {
    guard let summary = costEstimator.cachedInsights(
      provider: provider,
      account: account,
      credentialTransition: credentialTransition,
      now: now,
      historyDays: 30
    ) else { return .missing }
    return summary.hasDisplayableActivity ? .loaded(summary) : .empty
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
      switch cachedUsageInsights(
        provider: provider,
        account: account,
        credentialTransition: credentialTransition,
        now: now
      ) {
      case let .loaded(summary):
        usageInsightsStates[provider] = .loaded(summary)
      case .empty:
        usageInsightsStates[provider] = .empty(.noLocalUsage)
      case .missing:
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

private extension UsageInsightsSummary {
  var hasDisplayableActivity: Bool {
    daily.contains { day in
      (day.spend.value ?? 0) > 0 || (day.tokens.total.value ?? 0) > 0
    }
  }
}
