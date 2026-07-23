import CustomDump
import Foundation
@testable import QuotariCore
import Testing

extension LocalUsageInsightsEstimatorTests {
  @Test func mixedClaudeSessionsCarryUnsupportedCoverageAndIdentity() async throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    try fixture.writeAdditionalPlaceholderUsage()

    let summary = try #require(await fixture.estimator().insights(
      provider: .claude,
      account: fixture.account(identity: "current-token"),
      now: fixture.now,
      historyDays: 30
    ))

    expectNoDifference(summary.period(.thirtyDays)?.sessionCount, .available(2))
    expectNoDifference(
      summary.period(.thirtyDays)?.tokens.total,
      .partial(value: 80, limitation: .unsupportedTokenFields)
    )
    expectNoDifference(
      summary.period(.thirtyDays)?.models.first?.tokens.total,
      .partial(value: 80, limitation: .unsupportedTokenFields)
    )
    let outcome = await fixture.estimator().costRefreshOutcome(
      provider: .claude,
      account: fixture.account(identity: "current-token"),
      now: fixture.now,
      historyDays: 30
    )
    guard case let .updated(cost) = outcome else {
      Issue.record("Expected mixed supported usage to remain available to the legacy UI")
      return
    }
    expectNoDifference(cost.estimateLimitation, .unsupportedTokenFields)
  }

  @Test func automaticAccountDisclosesSharedLocalProvenance() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }

    let summary = try #require(await fixture.estimator().insights(
      provider: .codex,
      account: nil,
      now: fixture.now,
      historyDays: 30
    ))

    expectNoDifference(summary.accountScope, .sharedLocalCache)
    expectNoDifference(
      summary.sourceDescription,
      "Estimated from local Codex logs (not account-specific)"
    )
  }

  @Test func mismatchedProviderAccountCannotInvalidateTheProvidersSharedCache() async throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let summary = try #require(await estimator.insights(
      provider: .claude,
      account: nil,
      now: fixture.now,
      historyDays: 30
    ))
    let codexAccount = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: nil,
      credentialSource: .codexAuthFile(path: fixture.root.appendingPathComponent("auth.json").path)
    )

    let outcome = await estimator.costRefreshOutcome(
      provider: .claude,
      account: codexAccount,
      now: fixture.now,
      historyDays: 30
    )
    expectNoDifference(
      outcome,
      .confirmedEmpty
    )
    expectNoDifference(
      estimator.cachedInsights(
        provider: .claude,
        account: nil,
        now: fixture.now,
        historyDays: 30
      ),
      summary
    )
  }

  @Test func sharedClaudeScopeCanonicalizesAndSortsConfiguredRoots() throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let otherConfig = fixture.root.appendingPathComponent("other-claude", isDirectory: true)
    try FileManager.default.createDirectory(
      at: otherConfig.appendingPathComponent("projects", isDirectory: true),
      withIntermediateDirectories: true
    )
    let first = LocalUsageCostEstimator.testing(
      environment: ["CLAUDE_CONFIG_DIR": "\(fixture.config.path),\(otherConfig.path)"],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )
    let second = LocalUsageCostEstimator.testing(
      environment: ["CLAUDE_CONFIG_DIR": "\(otherConfig.path),\(fixture.config.path)"],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )

    expectNoDifference(
      first.resolvedInsightsScope(provider: .claude, account: nil)?.key,
      second.resolvedInsightsScope(provider: .claude, account: nil)?.key
    )
  }

  @Test func defaultClaudeAutomaticAndSelectedModesShareTheEffectiveRootScope() throws {
    let fixture = try ClaudeInsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()

    expectNoDifference(
      estimator.resolvedInsightsScope(provider: .claude, account: nil)?.key,
      estimator.resolvedInsightsScope(
        provider: .claude,
        account: fixture.account(identity: "current-token")
      )?.key
    )
  }

  @Test func confirmedEmptyRootTransitionCannotResurrectThePreviousCache() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = fixture.estimator()
    let account = fixture.codexAccount(identity: "account")
    let sessions = fixture.codexHome.appendingPathComponent("sessions", isDirectory: true)

    #expect(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) != nil)

    try FileManager.default.removeItem(at: sessions)
    let emptyOutcome = await estimator.costRefreshOutcome(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    )
    expectNoDifference(
      emptyOutcome,
      .confirmedEmpty
    )
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func canceledAnalysisCannotRepopulateAnInvalidatedCache() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let pricing = BlockingPricingCatalogProvider()
    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache,
      pricingCatalogProvider: pricing
    )
    let account = fixture.codexAccount(identity: "account")
    let task = Task {
      await estimator.insights(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      )
    }
    await pricing.waitUntilRequested()

    task.cancel()
    estimator.invalidateInsights(provider: .codex, account: account, historyDays: 30)
    await pricing.finish()

    #expect(await task.value == nil)
    #expect(estimator.cachedInsights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func invalidationAtTheWriteBoundaryWinsOverTheAnalysis() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let hook = BlockingCacheMutationHook()
    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache,
      pricingCatalogProvider: BundledPricingCatalogProvider(),
      cacheMutationHook: { hook.pause() }
    )
    let account = fixture.codexAccount(identity: "account")
    let task = Task {
      await estimator.insights(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      )
    }
    await hook.waitUntilReached()

    estimator.invalidateInsights(provider: .codex, account: account, historyDays: 30)
    hook.finish()

    #expect(await task.value == nil)
    #expect(estimator.cachedInsights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }
}
