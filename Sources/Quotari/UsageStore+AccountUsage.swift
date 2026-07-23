import Foundation
import QuotariCore

extension UsageStore {
  subscript(selectedAccountID provider: UsageProvider) -> String {
    get { selectedAccounts[provider]?.id ?? "" }
    set { selectAccount(id: newValue.isEmpty ? nil : newValue, for: provider) }
  }

  /// The explicitly selected account, or the discovered account the current
  /// provider snapshot confidently names. Without either there is no active
  /// account — guessing would mark the wrong account as active and let
  /// unattributed provider data surface under a real account.
  func activeAccount(for provider: UsageProvider) -> ProviderAccount? {
    guard isProviderEnabled(provider) else { return nil }
    if let selected = selectedAccounts[provider] {
      return selected
    }
    guard let accountName = snapshots[provider]?.account else { return nil }
    return (accounts[provider] ?? []).first { accountMatchesSnapshot($0, name: accountName) }
  }

  /// Whether the snapshot's account name names this account. The provider
  /// usage payload reports the email, so this matches the fetched profile
  /// email (the visible label) as well as the discovered display name —
  /// otherwise a Claude row labeled by email would never match its own usage.
  func selectAccount(id: String?, for provider: UsageProvider) {
    let account = id.flatMap { id in accounts[provider]?.first { $0.id == id } }
    selectAccount(account, for: provider)
  }

  func selectAccount(_ account: ProviderAccount?, for provider: UsageProvider) {
    // Picking a live row that stands in for a hidden saved copy means picking
    // that saved account: anchor to it so a later slot reuse falls back to it
    // instead of following the slot.
    let origin = account.flatMap { capturedEquivalents[$0.id] }
    selectAccount(account, for: provider, standingInFor: origin)
  }

  /// The selections as they should survive a relaunch: a live stand-in is
  /// stored as the saved account it stands in for.
  func persistableSelections() -> [UsageProvider: ProviderAccount] {
    var stored = selectedAccounts
    for (provider, origin) in reconciledSelectionOrigins {
      stored[provider] = origin
    }
    return stored
  }

  func accountUsage(for account: ProviderAccount) -> ProviderAccountUsage? {
    guard isProviderEnabled(account.provider) else { return nil }
    if let usage = currentAccountUsage(for: account) {
      return usage
    }
    guard activeAccount(for: account.provider)?.id == account.id,
          let snapshot = snapshots[account.provider]
    else { return nil }
    return ProviderAccountUsage(
      snapshot: snapshot,
      sourceLabel: sourceLabels[account.provider],
      sourceKind: nil,
      error: errors[account.provider]
    )
  }

  func refreshAccountUsage(
    for provider: UsageProvider,
    force: Bool = false,
    notifiesQuota: Bool = false,
    includingLogicalAccountIDs: Set<String>? = nil,
    excludingCredentialScopeIDs: Set<String> = [],
    interaction: ProviderFetchInteraction = .background,
    bypassesDelayedCredentialRefresh: Bool = false
  ) async {
    if case .userInitiated = interaction {
      await cancelDelayedCredentialRefreshAndDrainSelection(for: provider)
    } else if !bypassesDelayedCredentialRefresh {
      await waitForDelayedCredentialRefreshAndDrainSelection(for: provider)
    }
    // A per-account fetch can rotate/persist a live token; never start one
    // while a switch is rewriting a credential slot.
    guard !Task.isCancelled, !isSwitching, isProviderEnabled(provider) else { return }
    await waitForAutomaticCaptureBeforeAccountUsage(provider)
    guard !isSwitching, isProviderEnabled(provider) else { return }
    let request = AccountUsageRefreshRequest(
      force: force, notifiesQuota: notifiesQuota,
      includingLogicalAccountIDs: includingLogicalAccountIDs,
      excludingCredentialScopeIDs: excludingCredentialScopeIDs,
      interaction: interaction,
      bypassesDelayedCredentialRefresh: bypassesDelayedCredentialRefresh
    )
    guard await joinsAccountUsageRefresh(provider, request: request) == false else { return }
    guard let descriptor = providers.first(where: { $0.id == provider }) else { return }
    let now = Date()
    let accountsToFetch = preparedAccountUsageRefreshAccounts(provider, now: now, request: request)
    guard accountUsageRefreshWillStart(accountsToFetch, provider: provider) else { return }

    refreshingAccountUsageProviders.insert(provider)
    let revision = accountRevisions[provider] ?? 0
    let execution = AccountUsageRefreshExecution(
      descriptor: descriptor,
      accounts: accountsToFetch,
      now: now,
      revision: revision,
      notifiesQuota: notifiesQuota,
      interaction: interaction
    )
    let task = accountUsageRefreshTask(provider: provider, execution: execution)
    accountUsageRefreshTasks[provider] = AccountUsageRefreshTask(
      task: task,
      force: force,
      notifiesQuota: notifiesQuota,
      revision: revision,
      credentialScopeIDs: Set(accountsToFetch.map(\.credentialScopeID)),
      interaction: interaction
    )
    _ = await task.value
    await retryNotifyingAccountUsageRefreshIfNeeded(
      provider: provider,
      revision: revision,
      request: request
    )
  }

  func refreshAccountUsage(
    for account: ProviderAccount,
    force: Bool = false,
    interaction: ProviderFetchInteraction = .background
  ) async {
    await waitForAutomaticCaptureBeforeAccountUsage(account.provider)
    guard !isSwitching, isProviderEnabled(account.provider),
          let currentAccount = monitoredAccount(afterCapturing: account)
    else { return }
    await refreshAccountUsage(
      for: account.provider,
      force: force,
      includingLogicalAccountIDs: [logicalMonitoringAccountID(for: currentAccount)],
      interaction: interaction
    )
  }

  func logicalMonitoringAccountID(for account: ProviderAccount) -> String {
    if account.credentialSource.isCaptured {
      return account.id
    }
    return capturedEquivalents[account.id]?.id ?? account.id
  }

  private func monitoredAccount(afterCapturing account: ProviderAccount) -> ProviderAccount? {
    let logicalAccountID = account.credentialSource.isCaptured
      ? account.id
      : capturedEquivalents[account.id]?.id
    return (monitoredAccounts[account.provider] ?? []).first { current in
      if let logicalAccountID {
        return current.id == logicalAccountID
          || capturedEquivalents[current.id]?.id == logicalAccountID
      }
      return current.id == account.id
        && current.credentialScopeID == account.credentialScopeID
    }
  }

  func reconcileAccountUsage(
    provider: UsageProvider,
    previousAccounts: [ProviderAccount],
    currentAccounts: [ProviderAccount]
  ) {
    let currentIDs = Set(currentAccounts.map(\.id))
    var usage = accountUsage[provider] ?? [:]
    usage = usage.filter { currentIDs.contains($0.key) }
    for account in currentAccounts {
      if let previous = previousAccounts.first(where: { $0.id == account.id }),
         previous != account {
        usage[account.id] = nil
      }
    }
    accountUsage[provider] = usage.isEmpty ? nil : usage
  }

  func recordAccountUsageSuccess(
    _ value: ProviderFetchResult,
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> UsageSnapshot {
    let usage = Self.normalizedSnapshot(value.usage, account: account)
    guard isProviderEnabled(provider) else { return usage }
    if let resolvedAccount = account
      ?? accountIdentified(by: value, provider: provider)
      ?? matchedAccount(for: usage, provider: provider) {
      setAccountUsage(
        ProviderAccountUsage(
          snapshot: usage,
          sourceLabel: value.sourceLabel,
          sourceKind: value.sourceKind,
          credentialScopeID: value.credentialScopeID,
          error: nil
        ),
        for: resolvedAccount
      )
    }
    return usage
  }

  func recordAccountUsageFailure(
    _ error: Error,
    provider: UsageProvider,
    account: ProviderAccount?
  ) {
    // Automatic-mode failures stay at the provider level (errors[provider]);
    // guessing an account here would blame the wrong credentials.
    guard isProviderEnabled(provider), let account else { return }
    var usage = accountUsage[provider]?[account.id] ?? ProviderAccountUsage()
    usage.error = error.localizedDescription
    setAccountUsage(usage, for: account)
  }

  /// Cached usage older than this is not shown as current; selection falls
  /// back to a clean loading state and waits for the follow-up refresh.
  nonisolated static let cachedAccountUsageLifetime: TimeInterval = 30 * 60

  /// `carryingForwardFrom` lets a same-account mirror keep the local cost
  /// chart already on the dashboard; account switches must leave it nil so
  /// another account's cost never carries over.
  func applyCachedAccountUsage(
    _ usage: ProviderAccountUsage?,
    account: ProviderAccount?,
    provider: UsageProvider,
    carryingForwardFrom previous: UsageSnapshot? = nil
  ) {
    guard let account, let usage, let snapshot = usage.snapshot,
          !Self.isExpired(snapshot)
    else {
      snapshots[provider] = nil
      errors[provider] = nil
      sourceLabels[provider] = nil
      return
    }
    let needsLocalCost = Self.shouldUseLocalCost(existing: snapshot.cost)
    let cachedCost = needsLocalCost
      ? costEstimator.cachedCostSummary(
        provider: provider,
        account: account,
        now: snapshot.updatedAt,
        historyDays: 30
      )
      : nil
    snapshots[provider] = Self.displaySnapshot(
      from: snapshot,
      previous: previous,
      cachedCost: cachedCost,
      prefersLocalCost: needsLocalCost
    )
    errors[provider] = usage.error
    sourceLabels[provider] = usage.sourceLabel
  }

  /// The picker treats any snapshot it receives as current, so an expired
  /// one is stripped here — mirroring the dashboard's lifetime gate — and
  /// only a remaining error is worth surfacing.
  private func currentAccountUsage(for account: ProviderAccount) -> ProviderAccountUsage? {
    guard var usage = accountUsage[account.provider]?[account.id] else { return nil }
    guard let snapshot = usage.snapshot, Self.isExpired(snapshot) else { return usage }
    usage.snapshot = nil
    return usage.error == nil ? nil : usage
  }

  func applyAccountUsageResult(
    _ result: Result<ProviderFetchResult, Error>,
    account: ProviderAccount
  ) {
    switch result {
    case let .success(value):
      _ = recordAccountUsageSuccess(value, provider: account.provider, account: account)
    case let .failure(error):
      recordAccountUsageFailure(error, provider: account.provider, account: account)
    }
    syncSelectedAccountUsage(for: account)
  }

  /// Per-account refreshes land in `accountUsage`; mirror the selected
  /// account's result onto the dashboard so the card and the popover
  /// never show different numbers for the same account.
  private func syncSelectedAccountUsage(for account: ProviderAccount) {
    let provider = account.provider
    guard selectedAccounts[provider]?.id == account.id,
          let usage = accountUsage[provider]?[account.id]
    else { return }
    guard usage.snapshot != nil else {
      errors[provider] = usage.error // keep any prior snapshot
      return
    }
    applyCachedAccountUsage(
      usage,
      account: account,
      provider: provider,
      carryingForwardFrom: snapshots[provider]
    )
  }

  private func setAccountUsage(_ usage: ProviderAccountUsage, for account: ProviderAccount) {
    var providerUsage = accountUsage[account.provider] ?? [:]
    providerUsage[account.id] = usage
    accountUsage[account.provider] = providerUsage
  }

  /// Results without a confident name match stay unattributed rather than
  /// being credited to an arbitrary account.
  private nonisolated static func isExpired(_ snapshot: UsageSnapshot) -> Bool {
    Date().timeIntervalSince(snapshot.updatedAt) >= cachedAccountUsageLifetime
  }

  private nonisolated static func normalizedSnapshot(
    _ snapshot: UsageSnapshot,
    account: ProviderAccount?
  ) -> UsageSnapshot {
    guard let account, snapshot.account == nil else { return snapshot }
    var normalized = snapshot
    normalized.account = account.displayName
    return normalized
  }
}
