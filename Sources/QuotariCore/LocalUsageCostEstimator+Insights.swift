import Foundation

extension LocalUsageCostEstimator {
  public func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) -> UsageInsightsSummary? {
    guard let scope = resolvedInsightsScope(provider: provider, account: account) else { return nil }
    let historyDays = normalizedHistoryDays(historyDays)
    let mutationKey = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    return cacheCoordinator.read(key: mutationKey) {
      LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
        .load(scopeKey: scope.key, now: now, historyDays: historyDays)
    }
  }

  public func insights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) async -> UsageInsightsSummary? {
    guard case let .updated(summary) = await refreshInsights(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    ) else { return nil }
    return summary
  }

  public func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) async -> UsageCostRefreshOutcome {
    switch await refreshInsights(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    ) {
    case let .updated(summary):
      if let cost = summary.costSummary {
        return .updated(cost)
      }
      return .confirmedEmpty
    case .confirmedEmpty:
      return .confirmedEmpty
    case .unavailable:
      return .unavailable
    }
  }

  private func refreshInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> LocalUsageInsightsRefreshOutcome {
    guard let scope = resolvedInsightsScope(provider: provider, account: account) else {
      return unresolvedScopeOutcome(
        provider: provider,
        account: account,
        historyDays: historyDays
      )
    }
    let writeContext = beginCacheWriteContext(
      provider: provider,
      scope: scope,
      now: now,
      historyDays: historyDays
    )
    let historyDays = writeContext.historyDays
    let scan = await localUsageScan(
      provider: provider,
      account: account,
      now: now,
      historyDays: historyDays
    )
    guard !Task.isCancelled,
          resolvedInsightsScope(provider: provider, account: account) == scope
    else { return .unavailable }
    let preparedResult: LocalUsageScanResult
    switch scanResult(
      from: scan.outcome,
      provider: provider,
      scope: scope,
      historyDays: historyDays,
      mutationToken: writeContext.mutationToken
    ) {
    case let .ready(result):
      preparedResult = result
    case .confirmedEmpty:
      return .confirmedEmpty
    case .unavailable:
      return .unavailable
    }
    let summary = await buildSummary(
      provider: provider,
      result: preparedResult,
      scan: scan,
      scope: scope,
      now: now
    )
    guard !Task.isCancelled,
          resolvedInsightsScope(provider: provider, account: account) == scope,
          let summary
    else { return .unavailable }
    return cacheSummary(summary, context: writeContext)
  }

  private func cacheSummary(
    _ summary: UsageInsightsSummary,
    context: LocalUsageCacheWriteContext
  ) -> LocalUsageInsightsRefreshOutcome {
    cacheMutationHook?()
    guard saveCachedAnalysis(summary, context: context) else { return .unavailable }
    return .updated(summary)
  }

  private func unresolvedScopeOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  ) -> LocalUsageInsightsRefreshOutcome {
    invalidateUnresolvedCredentialScope(
      provider: provider,
      account: account,
      historyDays: historyDays
    )
    return .confirmedEmpty
  }

  public func invalidateInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int = 30
  ) {
    guard let scope = resolvedInsightsScope(provider: provider, account: account) else { return }
    let historyDays = normalizedHistoryDays(historyDays)
    let mutationKey = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    cacheCoordinator.invalidate(key: mutationKey) {
      removeCachedAnalysis(provider: provider, scope: scope, historyDays: historyDays)
    }
  }

  func resolvedInsightsScope(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> ResolvedUsageInsightsScope? {
    guard account?.provider == provider || account == nil else { return nil }
    guard let account else {
      return sharedInsightsScope(provider: provider, account: nil)
    }

    switch (provider, account.credentialSource) {
    case (.codex, .codexAuthFile), (.claude, .claudeCredentialsFile):
      guard exactCredentialSourceStillBelongs(to: account) else { return nil }
      return sharedInsightsScope(provider: provider, account: account)
    case (.codex, .codexKeychain), (.claude, .claudeEnvironment), (.claude, .claudeKeychain):
      return sharedInsightsScope(provider: provider, account: account)
    case (_, .quotariRegistry),
         (.codex, .claudeEnvironment),
         (.codex, .claudeKeychain),
         (.codex, .claudeCredentialsFile),
         (.claude, .codexAuthFile),
         (.claude, .codexKeychain):
      return nil
    }
  }

  private func sharedInsightsScope(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> ResolvedUsageInsightsScope? {
    let roots = LocalUsageCostScanner(
      environment: environment,
      homeDirectory: homeDirectory
    )
    .scopeIdentityRoots(provider: provider, account: account)
    guard !roots.isEmpty else { return nil }
    let rootIdentity = scopeIdentityStore.identities(for: roots).joined(separator: "\n")
    return ResolvedUsageInsightsScope(
      key: UsageInsightsScopeKey(
        provider: provider,
        accountScopeID: "shared:\(ProviderCredentialIdentity.fingerprint(of: rootIdentity))"
      ),
      accountScope: .sharedLocalCache
    )
  }

  private func invalidateUnresolvedCredentialScope(
    provider: UsageProvider,
    account: ProviderAccount?,
    historyDays: Int
  ) {
    guard let account, account.provider == provider else { return }
    switch (provider, account.credentialSource) {
    case (.codex, .codexAuthFile), (.claude, .claudeCredentialsFile):
      break
    case (.codex, .codexKeychain),
         (.codex, .claudeEnvironment),
         (.codex, .claudeKeychain),
         (.codex, .claudeCredentialsFile),
         (.codex, .quotariRegistry),
         (.claude, .codexAuthFile),
         (.claude, .codexKeychain),
         (.claude, .claudeEnvironment),
         (.claude, .claudeKeychain),
         (.claude, .quotariRegistry):
      return
    }
    guard let scope = sharedInsightsScope(provider: provider, account: account) else { return }
    let historyDays = normalizedHistoryDays(historyDays)
    let key = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    cacheCoordinator.invalidate(key: key) {
      removeCachedAnalysis(provider: provider, scope: scope, historyDays: historyDays)
    }
  }

  private func exactCredentialSourceStillBelongs(to account: ProviderAccount) -> Bool {
    let path: String
    switch account.credentialSource {
    case let .codexAuthFile(credentialPath), let .claudeCredentialsFile(credentialPath):
      path = credentialPath
    case .codexKeychain, .claudeEnvironment, .claudeKeychain, .quotariRegistry:
      return false
    }
    guard let payload = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let identity = ProviderCredentialIdentity.discoveredAccountIdentity(
            provider: account.provider,
            payload: payload
          )
    else { return false }
    let currentAccount = ProviderAccount(
      provider: account.provider,
      displayName: account.displayName,
      detail: account.detail,
      credentialSource: account.credentialSource,
      credentialIdentity: identity
    )
    return currentAccount.credentialScopeID == account.credentialScopeID
  }

  func normalizedHistoryDays(_ historyDays: Int) -> Int {
    max(1, min(365, historyDays))
  }

  private func beginCacheWriteContext(
    provider: UsageProvider,
    scope: ResolvedUsageInsightsScope,
    now: Date,
    historyDays: Int
  ) -> LocalUsageCacheWriteContext {
    let historyDays = normalizedHistoryDays(historyDays)
    let key = LocalUsageCacheMutationKey(scopeKey: scope.key, historyDays: historyDays)
    return LocalUsageCacheWriteContext(
      provider: provider,
      scope: scope,
      now: now,
      historyDays: historyDays,
      mutationToken: cacheCoordinator.begin(key: key)
    )
  }

  private func localUsageScan(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> LocalUsageScan {
    await Task.detached(priority: .utility) {
      LocalUsageCostScanner(
        environment: environment,
        homeDirectory: homeDirectory
      )
      .scan(provider: provider, account: account, now: now, historyDays: historyDays)
    }.value
  }

  private func buildSummary(
    provider: UsageProvider,
    result: LocalUsageScanResult,
    scan: LocalUsageScan,
    scope: ResolvedUsageInsightsScope,
    now: Date
  ) async -> UsageInsightsSummary? {
    let pricingSnapshot = await pricingSnapshot(
      provider: provider,
      records: result.records,
      now: now
    )
    return await Task.detached(priority: .utility) {
      LocalUsageInsightsBuilder.summary(.init(
        provider: provider,
        records: result.records,
        unsupportedUsage: result.unsupportedUsage,
        range: scan.range,
        pricing: LocalModelPricing(snapshot: pricingSnapshot),
        scopeKey: scope.key,
        accountScope: scope.accountScope,
        generatedAt: now,
        sourceDescription: scan.sourceDescription
      ))
    }.value
  }

  private func pricingSnapshot(
    provider: UsageProvider,
    records: [LocalTokenRecord],
    now: Date
  ) async -> ModelPricingCatalogSnapshot {
    let keys = Set(records.compactMap { record in
      record.model.map { ModelPricingKey(provider: provider, modelID: $0) }
    })
    return keys.isEmpty
      ? .bundledOnly
      : await pricingCatalogProvider.snapshot(for: keys, now: now)
  }

  private func scanResult(
    from outcome: LocalUsageScanOutcome,
    provider: UsageProvider,
    scope: ResolvedUsageInsightsScope,
    historyDays: Int,
    mutationToken: LocalUsageCacheMutationToken
  ) -> LocalUsageScanPreparation {
    switch outcome {
    case let .success(result):
      return .ready(result)
    case .noLocalLogs:
      let removed = cacheCoordinator.performIfCurrent(mutationToken) {
        removeCachedAnalysis(
          provider: provider,
          scope: scope,
          historyDays: historyDays
        )
      }
      return removed ? .confirmedEmpty : .unavailable
    case .unsupportedUsage, .failure:
      // Preserve the previous valid summary until a later scan can prove a
      // replacement value.
      return .unavailable
    }
  }

  private func removeCachedAnalysis(
    provider: UsageProvider,
    scope: ResolvedUsageInsightsScope,
    historyDays: Int
  ) {
    LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
      .remove(scopeKey: scope.key, historyDays: historyDays)
    LocalUsageCostCache(cacheDirectory: cacheDirectory)
      .remove(
        provider: provider,
        scopeID: scope.legacyCostScopeID,
        historyDays: historyDays
      )
  }

  @discardableResult
  private func saveCachedAnalysis(
    _ summary: UsageInsightsSummary,
    context: LocalUsageCacheWriteContext
  ) -> Bool {
    cacheCoordinator.performIfCurrent(context.mutationToken) {
      LocalUsageInsightsCache(cacheDirectory: insightsCacheDirectory)
        .save(summary, now: context.now, historyDays: context.historyDays)
      let legacyCache = LocalUsageCostCache(cacheDirectory: cacheDirectory)
      if let costSummary = summary.costSummary {
        legacyCache.save(
          costSummary,
          provider: context.provider,
          scopeID: context.scope.legacyCostScopeID,
          now: context.now,
          historyDays: context.historyDays
        )
      } else {
        legacyCache.remove(
          provider: context.provider,
          scopeID: context.scope.legacyCostScopeID,
          historyDays: context.historyDays
        )
      }
    }
  }
}
