import Foundation

extension LocalUsageCostEstimator {
  public func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) -> UsageInsightsSummary? {
    cachedInsights(
      provider: provider,
      account: account,
      credentialTransition: nil,
      now: now,
      historyDays: historyDays
    )
  }

  public func cachedInsights(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int = 30
  ) -> UsageInsightsSummary? {
    guard let scope = resolvedInsightsScope(
      provider: provider,
      account: account,
      credentialTransition: credentialTransition
    ) else { return nil }
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
    guard case let .updated(summary) = await refreshInsights(.init(
      provider: provider,
      account: account,
      credentialTransition: nil,
      now: now,
      historyDays: historyDays
    )) else { return nil }
    return summary
  }

  public func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int = 30
  ) async -> UsageCostRefreshOutcome {
    await costRefreshOutcome(
      provider: provider,
      account: account,
      credentialTransition: nil,
      now: now,
      historyDays: historyDays
    )
  }

  public func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int = 30
  ) async -> UsageCostRefreshOutcome {
    switch await refreshInsights(.init(
      provider: provider,
      account: account,
      credentialTransition: credentialTransition,
      now: now,
      historyDays: historyDays
    )) {
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
    _ request: LocalUsageInsightsRefreshRequest
  ) async -> LocalUsageInsightsRefreshOutcome {
    guard let scope = resolvedInsightsScope(for: request) else {
      return unresolvedScopeOutcome(
        provider: request.provider,
        account: request.account,
        historyDays: request.historyDays
      )
    }
    let writeContext = beginCacheWriteContext(
      provider: request.provider,
      scope: scope,
      now: request.now,
      historyDays: request.historyDays
    )
    let historyDays = writeContext.historyDays
    let scan = await localUsageScan(
      provider: request.provider,
      account: request.account,
      now: request.now,
      historyDays: historyDays
    )
    guard scopeIsCurrent(scope, for: request) else { return .unavailable }
    let preparedResult: LocalUsageScanResult
    switch scanResult(
      from: scan.outcome,
      provider: request.provider,
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
      provider: request.provider,
      result: preparedResult,
      scan: scan,
      scope: scope,
      now: request.now
    )
    guard scopeIsCurrent(scope, for: request), let summary
    else { return .unavailable }
    return cacheSummary(summary, context: writeContext)
  }

  private func resolvedInsightsScope(
    for request: LocalUsageInsightsRefreshRequest
  ) -> ResolvedUsageInsightsScope? {
    resolvedInsightsScope(
      provider: request.provider,
      account: request.account,
      credentialTransition: request.credentialTransition
    )
  }

  private func scopeIsCurrent(
    _ scope: ResolvedUsageInsightsScope,
    for request: LocalUsageInsightsRefreshRequest
  ) -> Bool {
    !Task.isCancelled && resolvedInsightsScope(for: request) == scope
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

  func removeCachedAnalysis(
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
    if scope.previousCostScopeID != scope.legacyCostScopeID {
      LocalUsageCostCache(cacheDirectory: cacheDirectory)
        .remove(
          provider: provider,
          scopeID: scope.previousCostScopeID,
          historyDays: historyDays
        )
    }
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
      if context.scope.previousCostScopeID != context.scope.legacyCostScopeID {
        legacyCache.remove(
          provider: context.provider,
          scopeID: context.scope.previousCostScopeID,
          historyDays: context.historyDays
        )
      }
    }
  }
}
