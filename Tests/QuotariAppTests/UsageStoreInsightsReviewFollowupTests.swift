import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreInsightsReviewFollowupTests {
  @Test func cachedAccountInsightsUseTheActualCurrentDate() {
    let now = Date(timeIntervalSince1970: 1_783_479_000)
    let snapshotDate = now.addingTimeInterval(-15 * 60)
    let staleSummary = Self.summary(provider: .codex, now: snapshotDate)
    let estimator = DateSensitiveInsightsEstimator(
      staleLookupDate: snapshotDate,
      staleSummary: staleSummary
    )
    let account = Self.account(
      provider: .codex,
      source: .codexKeychain(service: "test", account: "current-date")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      costEstimator: estimator,
      currentDate: { now },
      startsAutomatically: false
    )
    let usage = ProviderAccountUsage(snapshot: UsageSnapshot(
      provider: .codex,
      plan: "Pro",
      primary: RateWindow(kind: .session, usedPercent: 25),
      updatedAt: snapshotDate
    ))

    store.applyCachedAccountUsage(usage, account: account, provider: .codex)

    #expect(estimator.insightsLookupDates == [now])
    #expect(store.usageInsightsState(for: .codex) == .idle)
  }

  @Test func cachedZeroActivitySummaryPreservesTheConfirmedEmptyState() {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let emptySummary = Self.summary(provider: .codex, now: now, tokensPerDay: 0, spendPerDay: 0)
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .codex)],
      costEstimator: FixedCachedInsightsEstimator(summary: emptySummary),
      currentDate: { now },
      startsAutomatically: false
    )
    store.usageInsightsStates[.codex] = .empty(.noLocalUsage)
    store.lastEmptyCostScans[.codex] = now

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: UsageSnapshot(
          provider: .codex,
          plan: "Pro",
          primary: RateWindow(kind: .session, usedPercent: 25),
          updatedAt: now
        ),
        sourceLabel: "Stub"
      ),
      provider: .codex,
      account: nil
    )

    #expect(store.usageInsightsState(for: .codex) == .empty(.noLocalUsage))
  }

  @Test func selectedAccountInsightsReceiveCredentialTransitionEvidence() throws {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let (account, rotated) = Self.claudeRotationAccounts()
    let transition = UsageCostCredentialTransition(
      targetScopeID: rotated.credentialScopeID,
      sourceScopeIDs: [account.credentialScopeID]
    )
    let summary = Self.summary(provider: .claude, now: now)
    let estimator = TransitionAwareInsightsEstimator(
      expectedTransition: transition,
      summary: summary
    )
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.claude: account])
    let store = UsageStore.isolatedForTesting(
      providers: [ProviderFixtures.descriptor(for: .claude)],
      costEstimator: estimator,
      accountSelectionStore: selectionStore,
      currentDate: { now },
      startsAutomatically: false
    )

    store.applyAccountUsageResult(
      .success(ProviderFetchResult(
        usage: UsageSnapshot(
          provider: .claude,
          plan: "Pro",
          primary: RateWindow(kind: .session, usedPercent: 25),
          updatedAt: now
        ),
        sourceLabel: "Stub",
        credentialScopeID: rotated.credentialScopeID,
        credentialTransitionTargetScopeID: rotated.credentialScopeID,
        credentialTransitionSourceScopeIDs: [account.credentialScopeID]
      )),
      account: account
    )

    #expect(estimator.receivedTransition == transition)
    #expect(store.usageInsightsState(for: .claude) == .loaded(summary))
  }

  private static func claudeRotationAccounts() -> (ProviderAccount, ProviderAccount) {
    let source = ProviderCredentialSource.claudeCredentialsFile(
      path: "/tmp/quotari-review-followup/.credentials.json"
    )
    return (
      ProviderAccount(
        provider: .claude,
        displayName: "Claude",
        detail: nil,
        credentialSource: source,
        credentialIdentity: "before"
      ),
      ProviderAccount(
        provider: .claude,
        displayName: "Claude",
        detail: nil,
        credentialSource: source,
        credentialIdentity: "after"
      )
    )
  }

  private static func account(
    provider: UsageProvider,
    source: ProviderCredentialSource
  ) -> ProviderAccount {
    ProviderAccount(
      provider: provider,
      displayName: "Test",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "identity"
    )
  }

  private static func summary(
    provider: UsageProvider,
    now: Date,
    tokensPerDay: Int = 100,
    spendPerDay: Double = 1
  ) -> UsageInsightsSummary {
    let tokens = UsageTokenBreakdown(
      input: .available(tokensPerDay),
      output: .available(0),
      cacheRead: .available(0),
      cacheWrite: .available(0),
      total: .available(tokensPerDay)
    )
    let coverage = CostEstimateCoverage(
      pricedTokens: tokensPerDay,
      unpricedTokens: 0
    )
    return UsageInsightsSummary(
      scopeKey: UsageInsightsScopeKey(
        provider: provider,
        accountScopeID: "review-followup"
      ),
      generatedAt: now,
      source: provider == .codex ? .localCodexLogs : .localClaudeCacheLogs,
      accountScope: .exact,
      sourceDescription: "Estimated from local logs",
      daily: (0 ..< 30).map { offset in
        DailyUsageInsight(
          date: now.addingTimeInterval(TimeInterval(offset - 29) * 86400),
          spend: .available(spendPerDay),
          tokens: tokens,
          sessionCount: .available(tokensPerDay > 0 ? 1 : 0),
          models: [],
          pricingCoverage: coverage
        )
      }
    )
  }
}

private final class DateSensitiveInsightsEstimator: @unchecked Sendable, UsageCostEstimating {
  let staleLookupDate: Date
  let staleSummary: UsageInsightsSummary
  private(set) var insightsLookupDates: [Date] = []

  init(staleLookupDate: Date, staleSummary: UsageInsightsSummary) {
    self.staleLookupDate = staleLookupDate
    self.staleSummary = staleSummary
  }

  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary? {
    insightsLookupDates.append(now)
    return now == staleLookupDate ? staleSummary : nil
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}

private struct FixedCachedInsightsEstimator: UsageCostEstimating {
  let summary: UsageInsightsSummary

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

private final class TransitionAwareInsightsEstimator: @unchecked Sendable, UsageCostEstimating {
  let expectedTransition: UsageCostCredentialTransition
  let summary: UsageInsightsSummary
  private(set) var receivedTransition: UsageCostCredentialTransition?

  init(
    expectedTransition: UsageCostCredentialTransition,
    summary: UsageInsightsSummary
  ) {
    self.expectedTransition = expectedTransition
    self.summary = summary
  }

  func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int
  ) -> UsageInsightsSummary? {
    receivedTransition = credentialTransition
    return credentialTransition == expectedTransition ? summary : nil
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}
