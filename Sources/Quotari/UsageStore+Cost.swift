import Foundation
import QuotariCore

struct ReportedCostFallback {
  let cost: CostSummary?
}

private struct LocalCostRefreshDecision {
  let needsLocalCost: Bool
  let cacheHit: Bool
}

extension UsageStore {
  func applySuccessfulFetch(
    _ value: ProviderFetchResult,
    provider: UsageProvider,
    account: ProviderAccount?
  ) {
    let usage = recordAccountUsageSuccess(value, provider: provider, account: account)
    let hidesProviderCost = Self.shouldHideProviderCost(sourceKind: value.sourceKind)
    let reportedCostFallback = Self.reportedCostFallback(
      from: usage.cost,
      hidesProviderCost: hidesProviderCost
    )
    let needsLocalCost = Self.shouldUseLocalCost(
      existing: usage.cost,
      sourceKind: value.sourceKind
    )
    let selectedAccount = selectedAccounts[provider]
    let cachedCost = needsLocalCost
      ? costEstimator.cachedCostSummary(
        provider: provider,
        account: selectedAccount,
        now: usage.updatedAt,
        historyDays: 30
      )
      : nil
    snapshots[provider] = Self.displaySnapshot(
      from: usage,
      previous: snapshots[provider],
      cachedCost: cachedCost,
      prefersLocalCost: needsLocalCost,
      hidesProviderCost: hidesProviderCost
    )
    sourceLabels[provider] = value.sourceLabel
    errors[provider] = nil
    updateCostRefresh(
      provider: provider,
      account: selectedAccount,
      now: usage.updatedAt,
      reportedCostFallback: reportedCostFallback,
      decision: LocalCostRefreshDecision(
        needsLocalCost: needsLocalCost,
        cacheHit: cachedCost != nil
      )
    )
  }

  nonisolated static func displaySnapshot(
    from snapshot: UsageSnapshot,
    previous: UsageSnapshot?,
    cachedCost: CostSummary?,
    prefersLocalCost: Bool,
    hidesProviderCost: Bool
  ) -> UsageSnapshot {
    guard prefersLocalCost else { return snapshot }
    var display = snapshot
    display.cost = cachedCost
      ?? previous?.cost.flatMap { shouldCarryForwardCost($0) ? $0 : nil }
      ?? snapshot.cost.flatMap { hidesProviderCost || shouldHideSparseReportedCost($0) ? nil : $0 }
    return display
  }

  nonisolated static func shouldUseLocalCost(
    existing cost: CostSummary?,
    sourceKind: ProviderFetchKind?
  ) -> Bool {
    if shouldHideProviderCost(sourceKind: sourceKind) {
      return true
    }
    return shouldUseLocalCost(existing: cost)
  }

  nonisolated static func shouldHideProviderCost(sourceKind: ProviderFetchKind?) -> Bool {
    sourceKind == .mock
  }

  private func updateCostRefresh(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    reportedCostFallback: CostSummary?,
    decision: LocalCostRefreshDecision
  ) {
    if decision.needsLocalCost {
      refreshCost(
        provider: provider,
        account: account,
        now: now,
        reportedCostFallback: reportedCostFallback,
        cacheHit: decision.cacheHit
      )
    } else {
      lastEmptyCostScans[provider] = nil
      latestReportedCostFallbacks[provider] = nil
      costTasks[provider]?.cancel()
      costTasks[provider] = nil
    }
  }

  private func refreshCost(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    reportedCostFallback: CostSummary?,
    cacheHit: Bool
  ) {
    latestReportedCostFallbacks[provider] = ReportedCostFallback(cost: reportedCostFallback)
    guard costTasks[provider] == nil else { return }
    if let lastEmptyCostScan = lastEmptyCostScans[provider],
       now.timeIntervalSince(lastEmptyCostScan) < Self.localCostScanThrottle {
      return
    }
    if cacheHit,
       let lastCostScan = lastCostScans[provider],
       now.timeIntervalSince(lastCostScan) < Self.localCostScanThrottle {
      return
    }
    lastCostScans[provider] = now
    let revision = accountRevisions[provider] ?? 0
    let costEstimator = costEstimator
    costTasks[provider] = Task { [weak self] in
      let cost = await costEstimator.costSummary(
        provider: provider,
        account: account,
        now: now,
        historyDays: 30
      )
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.finishCostRefresh(
          cost,
          provider: provider,
          account: account,
          revision: revision
        )
      }
    }
  }

  private func finishCostRefresh(
    _ cost: CostSummary?,
    provider: UsageProvider,
    account: ProviderAccount?,
    revision: UInt
  ) {
    guard (accountRevisions[provider] ?? 0) == revision else { return }
    costTasks[provider] = nil
    guard let cost else {
      lastEmptyCostScans[provider] = Date()
      costEstimator.invalidateCachedCostSummary(
        provider: provider,
        account: account,
        historyDays: 30
      )
      let reportedCostFallback = latestReportedCostFallbacks[provider]?.cost
      clearLocalCost(provider: provider, reportedCostFallback: reportedCostFallback)
      return
    }
    lastEmptyCostScans[provider] = nil
    applyCost(cost, provider: provider)
  }

  private func applyCost(_ cost: CostSummary, provider: UsageProvider) {
    guard var snapshot = snapshots[provider],
          Self.canApplyLocalCost(over: snapshot.cost)
    else { return }
    snapshot.cost = cost
    snapshots[provider] = snapshot
  }

  private func clearLocalCost(provider: UsageProvider, reportedCostFallback: CostSummary?) {
    guard var snapshot = snapshots[provider],
          let cost = snapshot.cost,
          cost.sourceDescription.localizedCaseInsensitiveContains("local")
    else { return }
    snapshot.cost = reportedCostFallback
    snapshots[provider] = snapshot
  }

  private nonisolated static func shouldUseLocalCost(existing cost: CostSummary?) -> Bool {
    guard let cost else { return true }
    return !cost.hasTokenMetrics || cost.daily.count <= 1
  }

  private nonisolated static func shouldCarryForwardCost(_ cost: CostSummary) -> Bool {
    cost.sourceDescription.localizedCaseInsensitiveContains("local")
  }

  private nonisolated static func shouldHideSparseReportedCost(_ cost: CostSummary) -> Bool {
    !cost.hasTokenMetrics && cost.daily.count <= 1 && cost.monthSpend == 0 && cost.todaySpend == 0
  }

  private nonisolated static func reportedCostFallback(
    from cost: CostSummary?,
    hidesProviderCost: Bool
  ) -> CostSummary? {
    guard !hidesProviderCost,
          let cost,
          !cost.sourceDescription.localizedCaseInsensitiveContains("local"),
          !shouldHideSparseReportedCost(cost)
    else { return nil }
    return cost
  }

  private nonisolated static func canApplyLocalCost(over cost: CostSummary?) -> Bool {
    guard let cost else { return true }
    return shouldUseLocalCost(existing: cost) || cost.sourceDescription.localizedCaseInsensitiveContains("local")
  }
}
