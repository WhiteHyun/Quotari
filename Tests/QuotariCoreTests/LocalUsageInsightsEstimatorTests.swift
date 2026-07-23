import CustomDump
import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageInsightsEstimatorTests {
  @Test func credentialFileProducesScopeSafeSharedInsights() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let account = fixture.codexAccount(identity: "account")
    let estimator = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )

    let summary = try #require(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ))
    let period = try #require(summary.period(.thirtyDays))

    expectNoDifference(summary.accountScope, .sharedLocalCache)
    expectNoDifference(summary.source, .localCodexLogs)
    #expect(!summary.scopeKey.accountScopeID.contains(fixture.root.path))
    expectNoDifference(period.tokens.total, .available(170))
    expectNoDifference(period.sessionCount, .available(1))
    expectNoDifference(
      estimator.cachedInsights(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      ),
      summary
    )
    expectNoDifference(summary.costSummary?.monthTokens, 170)
    expectNoDifference(
      summary.sourceDescription,
      "Estimated from local Codex logs (not account-specific)"
    )

    estimator.invalidateInsights(provider: .codex, account: account, historyDays: 30)
    #expect(estimator.cachedInsights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func capturedAccountsDoNotInheritTheLiveScope() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )
    let captured = ProviderAccount(
      provider: .codex,
      displayName: "Saved",
      detail: nil,
      credentialSource: .quotariRegistry(id: "saved")
    )

    #expect(await estimator.insights(
      provider: .codex,
      account: captured,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    let outcome = await estimator.costRefreshOutcome(
      provider: .codex,
      account: captured,
      now: fixture.now,
      historyDays: 30
    )
    expectNoDifference(outcome, .confirmedEmpty)
  }

  @Test func reusedCodexCredentialSlotRejectsThePreviousLogicalAccount() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()

    #expect(await estimator.insights(
      provider: .codex,
      account: fixture.codexAccount(identity: "previous-account"),
      now: fixture.now,
      historyDays: 30
    ) == nil)
    let current = try #require(await estimator.insights(
      provider: .codex,
      account: fixture.codexAccount(identity: "account"),
      now: fixture.now,
      historyDays: 30
    ))
    expectNoDifference(current.accountScope, .sharedLocalCache)
  }

  @Test func reusedClaudeCredentialSlotRejectsThePreviousLogicalAccount() async throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()

    #expect(await estimator.insights(
      provider: .claude,
      account: fixture.account(identity: "previous-token"),
      now: fixture.now,
      historyDays: 30
    ) == nil)
    let current = try #require(await estimator.insights(
      provider: .claude,
      account: fixture.account(identity: "current-token"),
      now: fixture.now,
      historyDays: 30
    ))
    expectNoDifference(current.accountScope, .sharedLocalCache)
  }

  @Test func successfulEmptyScanReplacesThePreviousCachedSummary() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let account = fixture.codexAccount(identity: "account")
    #expect(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) != nil)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) != nil)

    try FileManager.default.removeItem(at: fixture.usageURL)
    let empty = try #require(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ))

    expectNoDifference(empty.period(.thirtyDays)?.spend, .available(0))
    expectNoDifference(empty.period(.thirtyDays)?.tokens.total, .available(0))
    expectNoDifference(
      estimator.cachedInsights(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      ),
      empty
    )

    estimator.invalidateInsights(provider: .codex, account: account, historyDays: 30)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func mixedMalformedScanPreservesThePreviousCachedSummary() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let account = fixture.codexAccount(identity: "account")
    let previous = try #require(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ))

    var mixed = try Data(contentsOf: fixture.usageURL)
    mixed.append(contentsOf: Data("\nnot-json".utf8))
    try mixed.write(to: fixture.usageURL)

    #expect(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    expectNoDifference(
      estimator.cachedInsights(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      ),
      previous
    )
  }

  @Test func missingLogRootRemovesThePreviousCachedSummary() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let account = fixture.codexAccount(identity: "account")
    #expect(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) != nil)

    try FileManager.default.removeItem(at: fixture.usageURL.deletingLastPathComponent())

    #expect(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    #expect(estimator.cachedInsights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func outOfWindowCodexRowsProduceConfirmedEmptyInsights() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    try fixture.writeCodexUsage(timestamp: "2026-05-01T09:00:00Z")

    let summary = try #require(await fixture.estimator().insights(
      provider: .codex,
      account: fixture.codexAccount(identity: "account"),
      now: fixture.now,
      historyDays: 30
    ))

    expectNoDifference(summary.period(.thirtyDays)?.tokens.total, .available(0))
  }

  @Test func claudePlaceholderOnlyRowsRemainUnsupportedInsteadOfZero() async throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    try fixture.writePlaceholderOnlyUsage()
    let account = fixture.account(identity: "current-token")
    let scan = LocalUsageCostScanner(environment: [:], homeDirectory: fixture.root)
      .scan(provider: .claude, account: account, now: fixture.now, historyDays: 30)

    guard case .unsupportedUsage = scan.outcome else {
      Issue.record("Expected placeholder-only Claude usage to remain unsupported")
      return
    }
    #expect(await fixture.estimator().insights(
      provider: .claude,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }
}
