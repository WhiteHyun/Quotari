import Foundation
import QuotariCore

extension UsageStore {
  func retryNotifyingAccountUsageRefreshIfNeeded(
    provider: UsageProvider,
    revision: UInt,
    request: AccountUsageRefreshRequest
  ) async {
    guard request.notifiesQuota,
          !isSwitching,
          isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) != revision
    else { return }
    // A selection change invalidates every result from the older account
    // generation. Retry the whole notifying request so non-selected monitors
    // are not stranded until the next timer tick.
    await refreshAccountUsage(
      for: provider,
      force: request.force,
      notifiesQuota: true,
      includingLogicalAccountIDs: request.includingLogicalAccountIDs,
      excludingCredentialScopeIDs: request.excludingCredentialScopeIDs
    )
  }

  func preparedAccountUsageRefreshAccounts(
    _ provider: UsageProvider,
    now: Date,
    request: AccountUsageRefreshRequest
  ) -> [ProviderAccount] {
    let accounts = accountsNeedingRefresh(
      provider, at: now, forced: request.force,
      including: request.includingLogicalAccountIDs,
      excluding: request.excludingCredentialScopeIDs
    )
    if request.notifiesQuota {
      enqueueCachedAccountUsageNotifications(
        provider: provider,
        now: now,
        excludingAccountIDs: Set(accounts.map(\.id)),
        includingLogicalAccountIDs: request.includingLogicalAccountIDs,
        excludingCredentialScopeIDs: request.excludingCredentialScopeIDs
      )
    }
    return accounts
  }

  func enqueueCachedNotificationsAfterJoining(
    _ current: AccountUsageRefreshTask,
    provider: UsageProvider,
    request: AccountUsageRefreshRequest
  ) {
    guard request.notifiesQuota, !current.task.isCancelled else { return }
    let now = Date()
    let accountsStillNeedingRefresh = accountsNeedingRefresh(
      provider,
      at: now,
      forced: request.force,
      including: request.includingLogicalAccountIDs,
      excluding: request.excludingCredentialScopeIDs.union(current.credentialScopeIDs)
    )
    enqueueCachedAccountUsageNotifications(
      provider: provider,
      now: now,
      excludingAccountIDs: Set(accountsStillNeedingRefresh.map(\.id)),
      includingLogicalAccountIDs: request.includingLogicalAccountIDs,
      excludingCredentialScopeIDs: request.excludingCredentialScopeIDs
        .union(current.credentialScopeIDs)
    )
  }

  func performAndCompleteAccountUsageRefresh(
    provider: UsageProvider,
    execution: AccountUsageRefreshExecution
  ) async -> AccountUsageRefreshOutcome {
    let outcome = await performAccountUsageRefresh(
      provider: provider,
      descriptor: execution.descriptor,
      accounts: execution.accounts,
      now: execution.now,
      revision: execution.revision
    )
    let canNotifyQuota = execution.notifiesQuota && accountUsageRefreshCanNotify(
      provider, revision: execution.revision, isCancelled: Task.isCancelled
    )
    completeAccountUsageRefresh(outcome, provider: provider, canNotifyQuota: canNotifyQuota)
    return outcome
  }

  func accountUsageRefreshCanNotify(
    _ provider: UsageProvider,
    revision: UInt,
    isCancelled: Bool
  ) -> Bool {
    !isCancelled && isProviderEnabled(provider)
      && (accountRevisions[provider] ?? 0) == revision
  }

  func completeAccountUsageRefresh(
    _ outcome: AccountUsageRefreshOutcome,
    provider: UsageProvider,
    canNotifyQuota: Bool
  ) {
    if canNotifyQuota {
      enqueueAccountUsageNotifications(outcome.notificationCandidates)
    }
    recordCompletedCredentialTransitions(outcome.credentialTransitions, provider: provider)
    refreshingAccountUsageProviders.remove(provider)
    accountUsageRefreshTasks[provider] = nil
  }

  func enqueueAccountUsageNotifications(
    _ candidates: [AccountUsageNotificationCandidate],
    includingLogicalAccountIDs: Set<String>? = nil,
    excludingCredentialScopeIDs: Set<String> = []
  ) {
    for candidate in candidates {
      let account = candidate.account
      guard includingLogicalAccountIDs?.contains(logicalMonitoringAccountID(for: account)) ?? true,
            !excludingCredentialScopeIDs.contains(account.credentialScopeID)
      else { continue }
      let value = candidate.result
      enqueueQuotaNotification(
        snapshot: value.usage,
        provider: account.provider,
        account: account,
        sourceKind: value.sourceKind,
        credentialScopeID: value.credentialScopeID
      )
    }
  }

  func enqueueCachedAccountUsageNotifications(
    provider: UsageProvider,
    now: Date,
    excludingAccountIDs: Set<String>,
    includingLogicalAccountIDs: Set<String>?,
    excludingCredentialScopeIDs: Set<String>
  ) {
    for account in monitoredAccounts[provider] ?? [] {
      guard !excludingAccountIDs.contains(account.id),
            includingLogicalAccountIDs?.contains(logicalMonitoringAccountID(for: account)) ?? true,
            !excludingCredentialScopeIDs.contains(account.credentialScopeID),
            let usage = accountUsage[provider]?[account.id],
            let snapshot = usage.snapshot,
            usage.sourceKind != .mock,
            !hasElapsedNotificationWindow(snapshot, at: now),
            usage.sourceKind != .oauth || usage.credentialScopeID != nil
      else { continue }
      enqueueQuotaNotification(
        snapshot: snapshot,
        provider: provider,
        account: account,
        sourceKind: usage.sourceKind,
        credentialScopeID: usage.credentialScopeID
      )
    }
  }
}
