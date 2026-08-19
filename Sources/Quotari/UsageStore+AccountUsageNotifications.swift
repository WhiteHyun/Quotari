import Foundation
import QuotariCore

extension UsageStore {
  func accountUsageRefreshTask(
    provider: UsageProvider,
    execution: AccountUsageRefreshExecution
  ) -> Task<AccountUsageRefreshOutcome, Never> {
    Task { [weak self] in
      guard let self else { return AccountUsageRefreshOutcome() }
      let outcome = await performAndCompleteAccountUsageRefresh(
        provider: provider,
        execution: execution
      )
      guard !Task.isCancelled,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == execution.revision
      else { return outcome }
      // Per-account fetches can rotate/persist a live token too; keep hidden
      // saved copies and their profile labels in step with that rotation.
      await syncCapturedCopies(of: capturedCopyCandidates.filter { $0.provider == provider })
      if provider == .claude {
        refreshClaudeProfiles()
      }
      return outcome
    }
  }

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
      excludingCredentialScopeIDs: request.excludingCredentialScopeIDs,
      interaction: request.interaction,
      bypassesDelayedCredentialRefresh: request.bypassesDelayedCredentialRefresh
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
    credentialLifecycleLogger.record(
      .monitoringPass,
      provider: provider,
      interaction: request.interaction,
      reason: request.force ? .forced : .scheduled,
      monitoredAccountCount: monitoredAccounts[provider]?.count ?? 0,
      eligibleAccountCount: accounts.count,
      timestamp: now
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
    let outcome = await performAccountUsageRefresh(provider: provider, execution: execution)
    let canNotifyQuota = execution.notifiesQuota && accountUsageRefreshCanNotify(
      provider, revision: execution.revision, isCancelled: Task.isCancelled
    )
    completeAccountUsageRefresh(outcome, provider: provider, canNotifyQuota: canNotifyQuota)
    return outcome
  }

  func performAccountUsageRefresh(
    provider: UsageProvider,
    execution: AccountUsageRefreshExecution
  ) async -> AccountUsageRefreshOutcome {
    await withTaskGroup(
      of: (ProviderAccount, Result<ProviderFetchResult, Error>).self,
      returning: AccountUsageRefreshOutcome.self
    ) { group in
      for account in execution.accounts {
        let capturedRegistryID = capturedRegistryID(for: account)
        let lifecycleAccount = capturedEquivalents[account.id] ?? account
        let fetch = LifecycleLoggedAccountFetch(
          descriptor: execution.descriptor,
          account: account,
          lifecycleAccount: lifecycleAccount,
          capturedRegistryID: capturedRegistryID,
          interaction: execution.interaction,
          now: execution.now,
          logger: credentialLifecycleLogger
        )
        group.addTask { await fetch() }
      }
      var credentialTransitions: [String: Set<String>] = [:]
      var notificationCandidates: [AccountUsageNotificationCandidate] = []
      for await (account, result) in group {
        if let transition = result.credentialTransitionEvidence {
          for sourceScopeID in transition.sourceScopeIDs {
            credentialTransitions[sourceScopeID, default: []].insert(transition.targetScopeID)
          }
        }
        guard !Task.isCancelled,
              isProviderEnabled(provider),
              (accountRevisions[provider] ?? 0) == execution.revision,
              accounts[provider]?.contains(account) == true
        else { continue }
        if case let .success(value) = result,
           !fetchResult(value, belongsTo: account) {
          // A mutable credential source can be replaced after discovery but
          // before its fetch reads the file/keychain. Never publish account B's
          // usage under the stale row for account A.
          continue
        }
        applyAccountUsageResult(result, account: account)
        if case let .success(value) = result {
          notificationCandidates.append(
            AccountUsageNotificationCandidate(account: account, result: value)
          )
        }
      }
      return AccountUsageRefreshOutcome(
        credentialTransitions: credentialTransitions,
        notificationCandidates: notificationCandidates
      )
    }
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

private struct LifecycleLoggedAccountFetch: Sendable {
  let descriptor: ProviderDescriptor
  let account: ProviderAccount
  let lifecycleAccount: ProviderAccount
  let capturedRegistryID: String?
  let interaction: ProviderFetchInteraction
  let now: Date
  let logger: CredentialLifecycleLogger

  func callAsFunction() async -> (ProviderAccount, Result<ProviderFetchResult, Error>) {
    logger.record(
      .validationStarted,
      provider: account.provider,
      account: lifecycleAccount,
      interaction: interaction,
      timestamp: now
    )
    let result = await descriptor.fetch(
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryID,
      interaction: interaction
    )
    switch result {
    case .success:
      logger.record(
        .validationSucceeded,
        provider: account.provider,
        account: lifecycleAccount,
        interaction: interaction
      )
    case let .failure(error):
      logger.record(
        .validationFailed,
        provider: account.provider,
        account: lifecycleAccount,
        interaction: interaction,
        failure: .classify(error)
      )
    }
    return (account, result)
  }
}
