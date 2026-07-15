import Foundation
import QuotariCore

extension UsageStore {
  func joinsAccountUsageRefresh(
    _ provider: UsageProvider,
    request: AccountUsageRefreshRequest
  ) async -> Bool {
    guard let current = accountUsageRefreshTasks[provider] else { return false }
    await awaitAccountUsageRefresh(
      current,
      provider: provider,
      request: request
    )
    return true
  }

  func accountUsageRefreshDidFindNoCandidates(_ provider: UsageProvider) {
    // The token may have rotated since the last label attempt — relabel so the
    // picker doesn't show a stale email even when no usage fetch is needed.
    if provider == .claude {
      refreshClaudeProfiles()
    }
  }

  func accountUsageRefreshWillStart(
    _ accounts: [ProviderAccount],
    provider: UsageProvider
  ) -> Bool {
    guard accounts.isEmpty else { return true }
    accountUsageRefreshDidFindNoCandidates(provider)
    return false
  }

  func waitForAutomaticCaptureBeforeAccountUsage(_ provider: UsageProvider) async {
    if automaticallyCapturingProviders.contains(provider) {
      await inFlightAccountReload?.value
    }
  }

  func accountsNeedingRefresh(
    _ provider: UsageProvider,
    at now: Date,
    forced: Bool,
    including: Set<String>?,
    excluding: Set<String>
  ) -> [ProviderAccount] {
    (monitoredAccounts[provider] ?? []).filter { account in
      guard including?.contains(logicalMonitoringAccountID(for: account)) ?? true else { return false }
      guard !excluding.contains(account.credentialScopeID) else { return false }
      guard !forced,
            let snapshot = accountUsage[provider]?[account.id]?.snapshot
      else { return true }
      return now.timeIntervalSince(snapshot.updatedAt) >= refreshInterval
        || hasElapsedNotificationWindow(snapshot, at: now)
    }
  }

  func hasElapsedNotificationWindow(_ snapshot: UsageSnapshot, at now: Date) -> Bool {
    [snapshot.primary, snapshot.secondary]
      .compactMap { $0?.resetsAt }
      .contains { $0 <= now }
  }

  private func awaitAccountUsageRefresh(
    _ current: AccountUsageRefreshTask,
    provider: UsageProvider,
    request: AccountUsageRefreshRequest
  ) async {
    let outcome = await current.task.value
    guard isProviderEnabled(provider) else { return }
    let hasStaleRevision = current.revision.map {
      $0 != (accountRevisions[provider] ?? 0)
    } == true
    if current.task.isCancelled || hasStaleRevision {
      // A joined caller must not replay the stale generation's cache or treat
      // its credential scopes as covered. Start a current-generation request.
      await refreshAccountUsage(
        for: provider,
        force: request.force,
        notifiesQuota: request.notifiesQuota,
        includingLogicalAccountIDs: request.includingLogicalAccountIDs,
        excludingCredentialScopeIDs: request.excludingCredentialScopeIDs
      )
      return
    }
    if request.notifiesQuota,
       !current.notifiesQuota,
       current.revision == (accountRevisions[provider] ?? 0) {
      enqueueAccountUsageNotifications(
        outcome.notificationCandidates,
        includingLogicalAccountIDs: request.includingLogicalAccountIDs,
        excludingCredentialScopeIDs: request.excludingCredentialScopeIDs
      )
    }
    enqueueCachedNotificationsAfterJoining(current, provider: provider, request: request)
    // Disabling cancels but intentionally retains the old handle until its
    // closure finishes. If the provider was re-enabled while that fetch was
    // draining, replace the cancelled generation instead of treating it as
    // a successful coalesced request and leaving the cleared cache empty.
    if request.force, !current.force {
      await refreshAccountUsage(
        for: provider,
        force: true,
        notifiesQuota: request.notifiesQuota,
        includingLogicalAccountIDs: request.includingLogicalAccountIDs,
        excludingCredentialScopeIDs: request.excludingCredentialScopeIDs
      )
    } else {
      let requestedScopeIDs = Set(accountsNeedingRefresh(
        provider,
        at: Date(),
        forced: request.force,
        including: request.includingLogicalAccountIDs,
        excluding: request.excludingCredentialScopeIDs
      ).map(\.credentialScopeID))
      guard !requestedScopeIDs.isSubset(of: current.credentialScopeIDs) else { return }
      await refreshAccountUsage(
        for: provider,
        force: request.force,
        notifiesQuota: request.notifiesQuota,
        includingLogicalAccountIDs: request.includingLogicalAccountIDs,
        excludingCredentialScopeIDs: request.excludingCredentialScopeIDs.union(current.credentialScopeIDs)
      )
    }
  }
}
