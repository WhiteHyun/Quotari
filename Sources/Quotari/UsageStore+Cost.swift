import Foundation
import QuotariCore

struct ReportedCostFallback {
  let cost: CostSummary?
}

private struct LocalCostRefreshRequest {
  let provider: UsageProvider
  let account: ProviderAccount?
  let credentialTransition: UsageCostCredentialTransition?
  let now: Date
  let reportedCostFallback: CostSummary?
  let cacheHit: Bool
}

private enum LocalCostRefreshStart {
  case skip
  case start(after: Task<Void, Never>?)
}

private struct CostRefreshContext {
  let provider: UsageProvider
  let account: ProviderAccount?
  let revision: UInt
  let generation: UUID
}

extension UsageStore {
  func applySuccessfulFetch(
    _ value: ProviderFetchResult,
    provider: UsageProvider,
    account: ProviderAccount?
  ) {
    guard isProviderEnabled(provider) else { return }
    let usage = recordAccountUsageSuccess(value, provider: provider, account: account)
    enqueueQuotaNotification(
      snapshot: value.usage,
      provider: provider,
      account: account,
      sourceKind: value.sourceKind,
      credentialScopeID: value.credentialScopeID
    )
    let reportedCostFallback = Self.reportedCostFallback(from: usage.cost)
    let needsLocalCost = Self.shouldUseLocalCost(existing: usage.cost)
    let selectedAccount = selectedAccounts[provider]
    let credentialTransition = value.usageCostCredentialTransition
    let cachedCost = needsLocalCost
      ? costEstimator.cachedCostSummary(
        provider: provider,
        account: selectedAccount,
        credentialTransition: credentialTransition,
        now: usage.updatedAt,
        historyDays: 30
      )
      : nil
    snapshots[provider] = Self.displaySnapshot(
      from: usage,
      previous: snapshots[provider],
      cachedCost: cachedCost,
      prefersLocalCost: needsLocalCost
    )
    sourceLabels[provider] = value.sourceLabel
    errors[provider] = nil
    updateCostRefresh(
      request: LocalCostRefreshRequest(
        provider: provider,
        account: selectedAccount,
        credentialTransition: credentialTransition,
        now: usage.updatedAt,
        reportedCostFallback: reportedCostFallback,
        cacheHit: cachedCost != nil
      ),
      needsLocalCost: needsLocalCost
    )
  }

  nonisolated static func displaySnapshot(
    from snapshot: UsageSnapshot,
    previous: UsageSnapshot?,
    cachedCost: CostSummary?,
    prefersLocalCost: Bool
  ) -> UsageSnapshot {
    guard prefersLocalCost else { return snapshot }
    var display = snapshot
    display.cost = cachedCost
      ?? previous?.cost.flatMap { shouldCarryForwardCost($0, now: snapshot.updatedAt) ? $0 : nil }
      ?? snapshot.cost.flatMap { shouldHideSparseReportedCost($0) ? nil : $0 }
    return display
  }

  private func updateCostRefresh(
    request: LocalCostRefreshRequest,
    needsLocalCost: Bool
  ) {
    if needsLocalCost {
      refreshCost(request)
    } else {
      lastEmptyCostScans[request.provider] = nil
      latestReportedCostFallbacks[request.provider] = nil
      cancelCostRefresh(for: request.provider)
    }
  }

  private func refreshCost(_ request: LocalCostRefreshRequest) {
    let provider = request.provider
    latestReportedCostFallbacks[provider] = ReportedCostFallback(cost: request.reportedCostFallback)
    guard case let .start(previousTask) = costRefreshStart(for: request) else { return }
    lastCostScans[provider] = request.now
    let costEstimator = costEstimator
    let generation = UUID()
    let context = CostRefreshContext(
      provider: provider,
      account: request.account,
      revision: accountRevisions[provider] ?? 0,
      generation: generation
    )
    let task = Task { [weak self] in
      await previousTask?.value
      let outcome: UsageCostRefreshOutcome = if Task.isCancelled {
        .unavailable
      } else {
        await costEstimator.costRefreshOutcome(
          provider: provider,
          account: request.account,
          credentialTransition: request.credentialTransition,
          now: request.now,
          historyDays: 30
        )
      }
      let wasCancelled = Task.isCancelled
      await MainActor.run {
        self?.finishCostRefresh(
          outcome,
          context: context,
          wasCancelled: wasCancelled
        )
      }
    }
    costTasks[provider] = CostRefreshTask(
      generation: generation,
      credentialTransitionTargetScopeID: request.credentialTransition?.targetScopeID,
      task: task
    )
  }

  private func costRefreshStart(for request: LocalCostRefreshRequest) -> LocalCostRefreshStart {
    if let existingTask = costTasks[request.provider] {
      if !existingTask.cancellationRequested,
         existingTask.credentialTransitionTargetScopeID == request.credentialTransition?.targetScopeID {
        return .skip
      }
      if !existingTask.cancellationRequested {
        existingTask.task.cancel()
      }
      return .start(after: existingTask.task)
    }
    if let lastEmptyCostScan = lastEmptyCostScans[request.provider],
       request.now.timeIntervalSince(lastEmptyCostScan) < Self.localCostScanThrottle {
      return .skip
    }
    if request.cacheHit,
       let lastCostScan = lastCostScans[request.provider],
       request.now.timeIntervalSince(lastCostScan) < Self.localCostScanThrottle {
      return .skip
    }
    return .start(after: nil)
  }

  func cancelCostRefresh(for provider: UsageProvider) {
    guard var costTask = costTasks[provider] else { return }
    costTask.task.cancel()
    costTask.cancellationRequested = true
    costTasks[provider] = costTask
  }

  private func finishCostRefresh(
    _ outcome: UsageCostRefreshOutcome,
    context: CostRefreshContext,
    wasCancelled: Bool
  ) {
    let provider = context.provider
    guard costTasks[provider]?.generation == context.generation else { return }
    costTasks[provider] = nil
    guard !wasCancelled,
          isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == context.revision
    else { return }
    let completionDate = currentDate()
    switch outcome {
    case let .updated(cost):
      lastEmptyCostScans[provider] = nil
      if Self.shouldCarryForwardCost(cost, now: completionDate) {
        applyCost(cost, provider: provider)
      } else {
        let reportedCostFallback = latestReportedCostFallbacks[provider]?.cost
        clearLocalCost(provider: provider, reportedCostFallback: reportedCostFallback)
      }
    case .confirmedEmpty:
      lastEmptyCostScans[provider] = completionDate
      let reportedCostFallback = latestReportedCostFallbacks[provider]?.cost
      clearLocalCost(provider: provider, reportedCostFallback: reportedCostFallback)
    case .unavailable:
      guard let cost = snapshots[provider]?.cost,
            !Self.shouldCarryForwardCost(cost, now: completionDate)
      else { return }
      let reportedCostFallback = latestReportedCostFallbacks[provider]?.cost
      clearLocalCost(provider: provider, reportedCostFallback: reportedCostFallback)
    }
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

  nonisolated static func shouldUseLocalCost(existing cost: CostSummary?) -> Bool {
    guard let cost else { return true }
    return !cost.hasTokenMetrics || cost.daily.count <= 1
  }

  private nonisolated static func shouldCarryForwardCost(
    _ cost: CostSummary,
    now: Date
  ) -> Bool {
    guard cost.sourceDescription.localizedCaseInsensitiveContains("local"),
          let lastDate = cost.daily.last?.date
    else { return false }
    return Calendar.current.isDate(lastDate, inSameDayAs: now)
  }

  private nonisolated static func shouldHideSparseReportedCost(_ cost: CostSummary) -> Bool {
    !cost.hasTokenMetrics && cost.daily.count <= 1 && cost.monthSpend == 0 && cost.todaySpend == 0
  }

  private nonisolated static func reportedCostFallback(from cost: CostSummary?) -> CostSummary? {
    guard let cost,
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

struct CostRefreshTask {
  let generation: UUID
  let credentialTransitionTargetScopeID: String?
  let task: Task<Void, Never>
  var cancellationRequested = false
}

private extension ProviderFetchResult {
  var usageCostCredentialTransition: UsageCostCredentialTransition? {
    guard let targetScopeID = credentialTransitionTargetScopeID,
          !credentialTransitionSourceScopeIDs.isEmpty
    else { return nil }
    return UsageCostCredentialTransition(
      targetScopeID: targetScopeID,
      sourceScopeIDs: credentialTransitionSourceScopeIDs
    )
  }
}
