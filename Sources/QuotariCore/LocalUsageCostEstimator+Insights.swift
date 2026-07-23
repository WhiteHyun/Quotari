import Foundation

extension LocalUsageCostEstimator {
  public func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) -> UsageInsightsSummary? {
    guard let scope = insightsScope(provider: provider, account: account) else { return nil }
    let historyDays = normalizedHistoryDays(historyDays)
    return LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
      .load(scopeKey: scope.key, now: now, historyDays: historyDays)
  }

  public func insights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) async -> UsageInsightsSummary? {
    guard let scope = insightsScope(provider: provider, account: account) else { return nil }
    let historyDays = normalizedHistoryDays(historyDays)
    let scan = await Task.detached(priority: .utility) {
      LocalUsageCostScanner(
        environment: environment,
        homeDirectory: homeDirectory
      )
      .scan(provider: provider, account: account, now: now, historyDays: historyDays)
    }.value
    let pricingKeys = Set(scan.records.compactMap { record in
      record.model.map { ModelPricingKey(provider: provider, modelID: $0) }
    })
    let pricingSnapshot = pricingKeys.isEmpty
      ? ModelPricingCatalogSnapshot.bundledOnly
      : await pricingCatalogProvider.snapshot(for: pricingKeys, now: now)
    let summary = await Task.detached(priority: .utility) {
      LocalUsageInsightsBuilder.summary(.init(
        provider: provider,
        records: scan.records,
        range: scan.range,
        pricing: LocalModelPricing(snapshot: pricingSnapshot),
        scopeKey: scope.key,
        accountScope: scope.accountScope,
        generatedAt: now,
        sourceDescription: scan.sourceDescription
      ))
    }.value

    if let summary {
      LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
        .save(summary, now: now, historyDays: historyDays)
    }
    return summary
  }

  public func invalidateInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int = 30
  ) {
    guard let scope = insightsScope(provider: provider, account: account) else { return }
    LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
      .remove(scopeKey: scope.key, historyDays: normalizedHistoryDays(historyDays))
  }

  private func insightsScope(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> ResolvedUsageInsightsScope? {
    guard account?.provider == provider || account == nil else { return nil }
    guard let account else {
      return sharedInsightsScope(provider: provider)
    }

    switch (provider, account.credentialSource) {
    case (.codex, .codexAuthFile), (.claude, .claudeCredentialsFile):
      return ResolvedUsageInsightsScope(
        key: UsageInsightsScopeKey(
          provider: provider,
          accountScopeID: "exact:\(ProviderCredentialIdentity.fingerprint(of: account.credentialScopeID))"
        ),
        accountScope: .exact
      )
    case (.codex, .codexKeychain), (.claude, .claudeEnvironment), (.claude, .claudeKeychain):
      return sharedInsightsScope(provider: provider)
    case (_, .quotariRegistry),
         (.codex, .claudeEnvironment),
         (.codex, .claudeKeychain),
         (.codex, .claudeCredentialsFile),
         (.claude, .codexAuthFile),
         (.claude, .codexKeychain):
      return nil
    }
  }

  private func sharedInsightsScope(provider: UsageProvider) -> ResolvedUsageInsightsScope {
    let rootIdentity: String = switch provider {
    case .codex:
      normalizedEnvironmentValue("CODEX_HOME")
        ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true).standardizedFileURL.path
    case .claude:
      normalizedEnvironmentValue("CLAUDE_CONFIG_DIR")
        ?? homeDirectory.standardizedFileURL.path
    }
    return ResolvedUsageInsightsScope(
      key: UsageInsightsScopeKey(
        provider: provider,
        accountScopeID: "shared:\(ProviderCredentialIdentity.fingerprint(of: rootIdentity))"
      ),
      accountScope: .sharedLocalCache
    )
  }

  private func normalizedEnvironmentValue(_ key: String) -> String? {
    guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty
    else { return nil }
    return value
  }

  private func normalizedHistoryDays(_ historyDays: Int) -> Int {
    max(1, min(365, historyDays))
  }
}

private struct ResolvedUsageInsightsScope: Sendable {
  var key: UsageInsightsScopeKey
  var accountScope: UsageInsightsAccountScope
}
