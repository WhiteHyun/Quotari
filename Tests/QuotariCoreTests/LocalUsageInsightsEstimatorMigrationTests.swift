import CustomDump
import Foundation
@testable import QuotariCore
import Testing

extension LocalUsageInsightsEstimatorTests {
  @Test func legacyFallbackFollowsTheValidatedLogicalSelection() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let currentAccount = fixture.codexAccount(identity: "account")
    let replacementAccount = fixture.codexAccount(identity: "replacement-account")
    let stale = try #require(await estimator.insights(
      provider: .codex,
      account: currentAccount,
      now: fixture.now,
      historyDays: 30
    )?.costSummary)
    LocalUsageCostCache(cacheDirectory: fixture.cache).save(
      stale,
      provider: .codex,
      scopeID: replacementAccount.costCacheScopeID,
      now: fixture.now,
      historyDays: 30
    )

    try FileManager.default.removeItem(at: fixture.usageURL)
    #expect(await estimator.insights(
      provider: .codex,
      account: currentAccount,
      now: fixture.now,
      historyDays: 30
    ) != nil)
    estimator.invalidateInsights(provider: .codex, account: currentAccount, historyDays: 30)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: currentAccount,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    try codexAuthPayload(accessToken: "replacement", accountID: "replacement-account")
      .write(to: fixture.codexHome.appendingPathComponent("auth.json"))

    expectNoDifference(
      estimator.cachedCostSummary(
        provider: .codex,
        account: replacementAccount,
        now: fixture.now,
        historyDays: 30
      ),
      stale
    )
  }

  @Test func selectedLegacyCostCacheMigratesToTheSharedRootScope() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let account = fixture.codexAccount(identity: "account")
    let cost = try #require(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    )?.costSummary)
    estimator.invalidateInsights(provider: .codex, account: account, historyDays: 30)
    let legacyCache = LocalUsageCostCache(cacheDirectory: fixture.cache)
    legacyCache.save(
      cost,
      provider: .codex,
      scopeID: account.costCacheScopeID,
      now: fixture.now,
      historyDays: 30
    )

    expectNoDifference(
      estimator.cachedCostSummary(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      ),
      cost
    )

    let scope = try #require(estimator.resolvedInsightsScope(provider: .codex, account: account))
    #expect(legacyCache.load(
      provider: .codex,
      scopeID: account.costCacheScopeID,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    expectNoDifference(
      legacyCache.load(
        provider: .codex,
        scopeID: scope.legacyCostScopeID,
        now: fixture.now,
        historyDays: 30
      ),
      cost
    )
  }

  @Test func automaticLegacyCostCacheMigratesToTheSharedRootScope() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let cost = try #require(await estimator.insights(
      provider: .codex,
      account: nil,
      now: fixture.now,
      historyDays: 30
    )?.costSummary)
    estimator.invalidateInsights(provider: .codex, account: nil, historyDays: 30)
    let legacyCache = LocalUsageCostCache(cacheDirectory: fixture.cache)
    legacyCache.save(
      cost,
      provider: .codex,
      scopeID: nil,
      now: fixture.now,
      historyDays: 30
    )

    expectNoDifference(
      estimator.cachedCostSummary(
        provider: .codex,
        account: nil,
        now: fixture.now,
        historyDays: 30
      ),
      cost
    )

    let scope = try #require(estimator.resolvedInsightsScope(provider: .codex, account: nil))
    #expect(legacyCache.load(
      provider: .codex,
      scopeID: nil,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    expectNoDifference(
      legacyCache.load(
        provider: .codex,
        scopeID: scope.legacyCostScopeID,
        now: fixture.now,
        historyDays: 30
      ),
      cost
    )
  }

  @Test func provenClaudeCredentialRotationKeepsTheSharedScopeAvailable() async throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let previousAccount = fixture.account(identity: "current-token")
    let previousCost = try #require(await estimator.insights(
      provider: .claude,
      account: previousAccount,
      now: fixture.now,
      historyDays: 30
    )?.costSummary)
    try Data(
      #"{"claudeAiOauth":{"accessToken":"rotated-token","refreshToken":"refresh"}}"#.utf8
    ).write(to: fixture.config.appendingPathComponent(".credentials.json"))
    let rotatedAccount = fixture.account(identity: "rotated-token")
    let transition = UsageCostCredentialTransition(
      targetScopeID: rotatedAccount.credentialScopeID,
      sourceScopeIDs: [previousAccount.credentialScopeID]
    )

    expectNoDifference(
      estimator.cachedCostSummary(
        provider: .claude,
        account: previousAccount,
        credentialTransition: transition,
        now: fixture.now,
        historyDays: 30
      ),
      previousCost
    )
    let outcome = await estimator.costRefreshOutcome(
      provider: .claude,
      account: previousAccount,
      credentialTransition: transition,
      now: fixture.now,
      historyDays: 30
    )
    guard case let .updated(refreshedCost) = outcome else {
      Issue.record("Expected the proven rotation to preserve the shared local scope")
      return
    }
    expectNoDifference(refreshedCost, previousCost)
  }

  @Test func unrelatedCredentialTransitionCannotClaimAReplacedClaudeSlot() async throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let previousAccount = fixture.account(identity: "previous-token")
    let currentAccount = fixture.account(identity: "current-token")
    let unrelatedAccount = fixture.account(identity: "unrelated-token")
    let transition = UsageCostCredentialTransition(
      targetScopeID: currentAccount.credentialScopeID,
      sourceScopeIDs: [unrelatedAccount.credentialScopeID]
    )

    #expect(estimator.cachedCostSummary(
      provider: .claude,
      account: previousAccount,
      credentialTransition: transition,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    let outcome = await estimator.costRefreshOutcome(
      provider: .claude,
      account: previousAccount,
      credentialTransition: transition,
      now: fixture.now,
      historyDays: 30
    )
    expectNoDifference(outcome, .confirmedEmpty)
  }
}
