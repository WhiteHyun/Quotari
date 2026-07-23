import Foundation

public protocol UsageInsightsAnalyzing: Sendable {
  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary?
  func insights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> UsageInsightsSummary?
  func invalidateInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  )
}

public protocol UsageCostEstimating: Sendable {
  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary?
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary?
  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome
  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome
  func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int)
  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> CostSummary?
  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int
  ) -> CostSummary?
  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> CostSummary?
  func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  )
}

public struct UsageCostCredentialTransition: Equatable, Sendable {
  public let targetScopeID: String
  public let sourceScopeIDs: Set<String>

  public init(targetScopeID: String, sourceScopeIDs: Set<String>) {
    self.targetScopeID = targetScopeID
    self.sourceScopeIDs = sourceScopeIDs
  }
}

public enum UsageCostRefreshOutcome: Equatable, Sendable {
  case updated(CostSummary)
  case confirmedEmpty
  case unavailable
}

public extension UsageCostEstimating {
  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary? {
    nil
  }

  func invalidateCachedCostSummary(provider: UsageProvider, historyDays: Int) {}

  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> CostSummary? {
    cachedCostSummary(provider: provider, now: now, historyDays: historyDays)
  }

  func cachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int
  ) -> CostSummary? {
    cachedCostSummary(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    )
  }

  func costSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> CostSummary? {
    await costSummary(provider: provider, now: now, historyDays: historyDays)
  }

  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome {
    guard let summary = await costSummary(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    ) else {
      guard !Task.isCancelled else { return .unavailable }
      invalidateCachedCostSummary(
        provider: provider,
        account: account,
        historyDays: historyDays
      )
      return .confirmedEmpty
    }
    return .updated(summary)
  }

  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome {
    await costRefreshOutcome(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    )
  }

  func invalidateCachedCostSummary(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  ) {
    invalidateCachedCostSummary(provider: provider, historyDays: historyDays)
  }
}
