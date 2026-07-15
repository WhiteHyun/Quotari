import Foundation
import QuotariCore

extension UsageStore {
  func joinsAccountUsageRefresh(
    _ provider: UsageProvider,
    force: Bool,
    includingLogicalAccountIDs: Set<String>?,
    excludingCredentialScopeIDs: Set<String>
  ) async -> Bool {
    guard let current = accountUsageRefreshTasks[provider] else { return false }
    await awaitAccountUsageRefresh(
      current,
      provider: provider,
      force: force,
      includingLogicalAccountIDs: includingLogicalAccountIDs,
      excludingCredentialScopeIDs: excludingCredentialScopeIDs
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
    }
  }

  private func awaitAccountUsageRefresh(
    _ current: AccountUsageRefreshTask,
    provider: UsageProvider,
    force: Bool,
    includingLogicalAccountIDs: Set<String>?,
    excludingCredentialScopeIDs: Set<String>
  ) async {
    _ = await current.task.value
    guard isProviderEnabled(provider) else { return }
    // Disabling cancels but intentionally retains the old handle until its
    // closure finishes. If the provider was re-enabled while that fetch was
    // draining, replace the cancelled generation instead of treating it as
    // a successful coalesced request and leaving the cleared cache empty.
    if current.task.isCancelled {
      await refreshAccountUsage(
        for: provider,
        force: force,
        includingLogicalAccountIDs: includingLogicalAccountIDs,
        excludingCredentialScopeIDs: excludingCredentialScopeIDs
      )
    } else if force, !current.force {
      await refreshAccountUsage(
        for: provider,
        force: true,
        includingLogicalAccountIDs: includingLogicalAccountIDs,
        excludingCredentialScopeIDs: excludingCredentialScopeIDs
      )
    } else {
      let requestedScopeIDs = Set(accountsNeedingRefresh(
        provider,
        at: Date(),
        forced: force,
        including: includingLogicalAccountIDs,
        excluding: excludingCredentialScopeIDs
      ).map(\.credentialScopeID))
      guard !requestedScopeIDs.isSubset(of: current.credentialScopeIDs) else { return }
      await refreshAccountUsage(
        for: provider,
        force: force,
        includingLogicalAccountIDs: includingLogicalAccountIDs,
        excludingCredentialScopeIDs: excludingCredentialScopeIDs.union(current.credentialScopeIDs)
      )
    }
  }
}
