import Foundation

struct ResolvedUsageInsightsScope: Equatable, Sendable {
  var key: UsageInsightsScopeKey
  var accountScope: UsageInsightsAccountScope
  var previousCostScopeID: String?

  var legacyCostScopeID: String {
    key.accountScopeID
  }
}

enum LocalUsageInsightsRefreshOutcome {
  case updated(UsageInsightsSummary)
  case confirmedEmpty
  case unavailable
}

enum LocalUsageScanPreparation {
  case ready(LocalUsageScanResult)
  case confirmedEmpty
  case unavailable
}

struct LocalUsageCacheWriteContext {
  let provider: UsageProvider
  let scope: ResolvedUsageInsightsScope
  let now: Date
  let historyDays: Int
  let mutationToken: LocalUsageCacheMutationToken
}

struct LocalUsageInsightsRefreshRequest {
  let provider: UsageProvider
  let account: ProviderAccount?
  let credentialTransition: UsageCostCredentialTransition?
  let now: Date
  let historyDays: Int
}
