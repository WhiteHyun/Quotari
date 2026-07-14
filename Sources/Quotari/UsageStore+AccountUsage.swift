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
  /// unattributed (or demo) provider data surface under a real account.
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
  /// Where a previously selected account landed after rediscovery, evaluated
  /// from the account the user *logically* selected: a live stand-in defers
  /// to the saved account it stands in for. When the saved account is
  /// discoverable (again), it is the selection — so a CLI slot reused by
  /// another login falls back to the saved copy instead of being silently
  /// followed. While the saved identity is the live login, the live account
  /// substitutes (fetching with the freshest credential) and the origin is
  /// remembered. A logical account discovery lost entirely is re-listed
  /// as-is so the selection isn't silently dropped.
  func reconciledSelection(
    _ selected: ProviderAccount,
    origin: ProviderAccount?,
    in accounts: inout [ProviderAccount]
  ) async -> SelectionUpdate? {
    let logical = origin ?? selected
    if let visible = accounts.first(where: { $0.id == logical.id }) {
      if visible == selected, origin == nil {
        return nil
      }
      return SelectionUpdate(account: visible, origin: nil)
    }
    if let live = await accountDiscovery.liveAccount(equivalentTo: logical, among: accounts) {
      if live == selected {
        return nil // the stand-in is already selected; the origin stays
      }
      return SelectionUpdate(account: live, origin: logical)
    }
    accounts.append(logical)
    return logical == selected ? nil : SelectionUpdate(account: logical, origin: nil)
  }

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

  /// Whether an account can be saved: already-captured entries, live logins
  /// whose identity is already saved (their registry row is just hidden), and
  /// static env tokens (no refresh token to keep them alive) are excluded.
  func isCapturable(_ account: ProviderAccount) -> Bool {
    guard capturedEquivalents[account.id] == nil else { return false }
    switch account.credentialSource {
    case .quotariRegistry, .claudeEnvironment: return false
    case .codexAuthFile, .claudeKeychain, .claudeCredentialsFile: return true
    }
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

  func refreshAccountUsage(for provider: UsageProvider, force: Bool = false) async {
    // A per-account fetch can rotate/persist a live token; never start one
    // while a switch is rewriting a credential slot.
    guard !isSwitching, isProviderEnabled(provider) else { return }
    if let current = accountUsageRefreshTasks[provider] {
      await awaitAccountUsageRefresh(current, provider: provider, force: force)
      return
    }
    guard let descriptor = providers.first(where: { $0.id == provider }) else { return }
    let now = Date()
    let accountsToFetch = accountsNeedingRefresh(for: provider, now: now, force: force)
    guard !accountsToFetch.isEmpty else {
      // No usage fetch needed, but the token may have rotated since the last
      // label attempt — relabel so the picker doesn't show a stale email.
      if provider == .claude {
        refreshClaudeProfiles()
      }
      return
    }

    refreshingAccountUsageProviders.insert(provider)
    let revision = accountRevisions[provider] ?? 0
    let task = Task { [weak self] in
      guard let self else { return }
      await performAccountUsageRefresh(
        provider: provider,
        descriptor: descriptor,
        accounts: accountsToFetch,
        now: now,
        revision: revision
      )
      refreshingAccountUsageProviders.remove(provider)
      accountUsageRefreshTasks[provider] = nil
      guard !Task.isCancelled,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == revision
      else { return }
      // Per-account fetches can rotate a live token too; keep any hidden
      // saved copy of that identity in step.
      await syncCapturedCopies(of: capturedCopyCandidates.filter { $0.provider == provider })
      // A per-account usage fetch can rotate/persist a Claude token (via the
      // strategy's refresh), so resolve email labels afterward too — otherwise
      // a label stuck behind an expired token wouldn't update until a full
      // dashboard refresh or reload.
      if provider == .claude {
        refreshClaudeProfiles()
      }
    }
    accountUsageRefreshTasks[provider] = AccountUsageRefreshTask(task: task, force: force)
    await task.value
  }

  private func awaitAccountUsageRefresh(
    _ current: AccountUsageRefreshTask,
    provider: UsageProvider,
    force: Bool
  ) async {
    await current.task.value
    guard isProviderEnabled(provider) else { return }
    // Disabling cancels but intentionally retains the old handle until its
    // closure finishes. If the provider was re-enabled while that fetch was
    // draining, replace the cancelled generation instead of treating it as
    // a successful coalesced request and leaving the cleared cache empty.
    if current.task.isCancelled {
      await refreshAccountUsage(for: provider, force: force)
    } else if force, !current.force {
      await refreshAccountUsage(for: provider, force: true)
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
    // The automatic pipeline falls back to demo data when the live fetch
    // fails; its fabricated snapshot must never be stored under a real account.
    if account == nil, value.sourceKind == .mock {
      return usage
    }
    if let resolvedAccount = account ?? matchedAccount(for: usage, provider: provider) {
      setAccountUsage(
        ProviderAccountUsage(
          snapshot: usage,
          sourceLabel: value.sourceLabel,
          sourceKind: value.sourceKind,
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
    let hidesProviderCost = Self.shouldHideProviderCost(sourceKind: usage.sourceKind)
    let needsLocalCost = Self.shouldUseLocalCost(
      existing: snapshot.cost,
      sourceKind: usage.sourceKind
    )
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
      prefersLocalCost: needsLocalCost,
      hidesProviderCost: hidesProviderCost
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

  private func accountsNeedingRefresh(
    for provider: UsageProvider,
    now: Date,
    force: Bool
  ) -> [ProviderAccount] {
    (accounts[provider] ?? []).filter { account in
      guard !force,
            let snapshot = accountUsage[provider]?[account.id]?.snapshot
      else { return true }
      return now.timeIntervalSince(snapshot.updatedAt) >= refreshInterval
    }
  }

  private func performAccountUsageRefresh(
    provider: UsageProvider,
    descriptor: ProviderDescriptor,
    accounts: [ProviderAccount],
    now: Date,
    revision: UInt
  ) async {
    await withTaskGroup(of: (ProviderAccount, Result<ProviderFetchResult, Error>).self) { group in
      for account in accounts {
        let capturedRegistryID = capturedRegistryID(for: account)
        group.addTask {
          await (
            account,
            descriptor.fetch(
              now: now,
              account: account,
              capturedRegistryID: capturedRegistryID
            )
          )
        }
      }
      for await (account, result) in group {
        guard !Task.isCancelled,
              isProviderEnabled(provider),
              (accountRevisions[provider] ?? 0) == revision,
              self.accounts[provider]?.contains(account) == true
        else { continue }
        applyAccountUsageResult(result, account: account)
      }
    }
  }

  private func applyAccountUsageResult(
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
