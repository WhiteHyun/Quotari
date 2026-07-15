import Foundation
import QuotariCore

extension UsageStore {
  /// Spawns a tracked dashboard refresh. UI and the timer go through this so
  /// `inFlightRefresh` always reflects the actually-running refresh an account
  /// switch may need to await. A second call while one is in flight coalesces
  /// through `refreshRequested` instead of replacing the handle with a task
  /// that would return immediately via the `isRefreshing` guard — otherwise a
  /// switch could await a no-op and race the real refresh's slot write.
  func beginRefresh(reusesLatestAccountReload: Bool = false) {
    // Don't start a fetch while a switch is rewriting a credential slot.
    guard !isSwitching else { return }
    guard inFlightRefresh == nil else {
      refreshRequested = true
      return
    }
    inFlightRefresh = Task { [weak self] in
      await self?.refresh(
        clearsInFlightRefresh: true,
        reusesLatestAccountReload: reusesLatestAccountReload
      )
    }
  }

  func refresh() async {
    await refresh(clearsInFlightRefresh: false, reusesLatestAccountReload: false)
  }

  private func refresh(
    clearsInFlightRefresh: Bool,
    reusesLatestAccountReload: Bool
  ) async {
    // Clear the tracked handle before this actor-isolated operation returns.
    // Doing it in the spawning task leaves an executor hop where a new request
    // can observe the completed task, set `refreshRequested`, and be stranded
    // when that task subsequently clears its handle and exits.
    defer {
      if clearsInFlightRefresh {
        inFlightRefresh = nil
      }
    }
    guard !isRefreshing else {
      refreshRequested = true
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }

    // A live stand-in can silently start pointing at a different login when
    // its CLI slot is reused; rediscover first so the timer path reconciles
    // the selection just like a manual reload.
    guard await prepareReconciledAccountsForRefresh(
      reusesLatestAccountReload: reusesLatestAccountReload
    ) else { return }
    repeat {
      refreshRequested = false
      // A switch can close the gate after the discovery await above, or while
      // draining a previous pass. Never begin another provider fetch inside
      // that protected write window.
      guard !isSwitching else { return }
      await performRefresh()
    } while refreshRequested
    // Self-heal email labels after a usage refresh may have rotated a token:
    // the access-token fingerprint changes, so this re-fetches exactly once.
    refreshClaudeProfiles()
  }

  func startTimer(reusesLatestAccountReloadForFirstRefresh: Bool = false) {
    timerTask?.cancel()
    timerTask = Task { [weak self] in
      var reusesLatestAccountReload = reusesLatestAccountReloadForFirstRefresh
      while !Task.isCancelled {
        guard let self else { break }
        beginRefresh(reusesLatestAccountReload: reusesLatestAccountReload)
        reusesLatestAccountReload = false
        await inFlightRefresh?.value
        let interval = refreshInterval
        try? await Task.sleep(for: .seconds(interval))
      }
    }
  }

  func prepareReconciledAccountsForRefresh(
    reusesLatestAccountReload: Bool = false
  ) async -> Bool {
    let hasMutableMonitoredAccount = monitoredAccounts.contains { provider, accounts in
      isProviderEnabled(provider) && accounts.contains { !$0.credentialSource.isCaptured }
    }
    guard !reconciledSelectionOrigins.isEmpty || hasMutableMonitoredAccount else { return true }
    guard !isSwitching else {
      // The switch already owes a post-write discovery. Queue this request
      // without making the refresh being drained wait behind its own gate.
      beginAccountRediscovery()
      return false
    }
    // Automatic startup has just awaited its account-reload generation before
    // it starts the timer. A newer Settings or activation reload may already
    // be queued behind that generation, so wait for the queue to become fully
    // current instead of fetching from the older snapshot. Later timer and
    // manual refreshes still initiate their own rediscovery.
    if reusesLatestAccountReload {
      while completedAccountRediscoveryRequest != accountRediscoveryRequest {
        guard !isSwitching else {
          beginAccountRediscovery()
          return false
        }
        startQueuedAccountRediscoveryIfNeeded()
        guard let accountReload = inFlightAccountReload else { return false }
        // Await the task rather than a particular generation waiter. A switch
        // can close the gate and stop this drain before the newest generation;
        // waiting on that generation here would deadlock with the switch that
        // is itself draining this refresh.
        await accountReload.value
      }
      guard !isSwitching else {
        beginAccountRediscovery()
        return false
      }
      return true
    }
    await reloadAccounts()
    guard !isSwitching else {
      // The switch may have closed the gate while this pre-existing discovery
      // was draining. Leave a fresh generation for the post-write pass and do
      // not fetch with the pre-switch account mapping.
      beginAccountRediscovery()
      return false
    }
    return true
  }

  func performRefresh() async {
    let now = Date()
    var fetchedCredentialScopeIDs: [UsageProvider: Set<String>] = [:]
    await withTaskGroup(
      of: (UsageProvider, ProviderFetchCompletion).self
    ) { group in
      for descriptor in enabledProviderDescriptors {
        group.addTask {
          await (
            descriptor.id,
            self.coordinatedProviderFetch(
              descriptor: descriptor,
              now: now
            )
          )
        }
      }
      for await (provider, completion) in group {
        guard isProviderEnabled(provider),
              (accountRevisions[provider] ?? 0) == completion.revision
        else { continue }
        fetchedCredentialScopeIDs[provider, default: []]
          .formUnion(credentialScopeIDsCovered(by: completion, provider: provider))
        apply(provider: provider, account: completion.account, result: completion.result)
      }
    }
    await refreshMonitoredAccountUsage(excluding: fetchedCredentialScopeIDs)
    lastRefresh = Date()
    // Hidden saved copies must track live-token rotations between account
    // reloads too — a slot swapped right after a rotation would otherwise
    // strand the copy on a consumed refresh token.
    await syncCapturedCopies(of: capturedCopyCandidates.filter { isProviderEnabled($0.provider) })
  }

  private func refreshMonitoredAccountUsage(
    excluding credentialScopeIDs: [UsageProvider: Set<String>]
  ) async {
    await withTaskGroup(of: Void.self) { group in
      for descriptor in enabledProviderDescriptors where !(monitoredAccounts[descriptor.id] ?? []).isEmpty {
        group.addTask {
          await self.refreshAccountUsage(
            for: descriptor.id,
            excludingCredentialScopeIDs: credentialScopeIDs[descriptor.id] ?? []
          )
        }
      }
    }
  }

  private func credentialScopeIDsCovered(
    by completion: ProviderFetchCompletion,
    provider: UsageProvider
  ) -> Set<String> {
    var scopeIDs = Set<String>()
    if let transition = completion.result.credentialTransitionEvidence {
      // A refresh may rotate the credential before a later usage request
      // fails. The proven source scopes still belong to this fetch and must
      // not be refreshed again through the stale discovered rows.
      scopeIDs.formUnion(transition.sourceScopeIDs)
    }
    guard case let .success(value) = completion.result, value.sourceKind != .mock else {
      return scopeIDs
    }
    if let fetchedAccount = completion.account,
       !fetchResult(value, belongsTo: fetchedAccount) {
      // The mutable slot was replaced by an unrelated login after discovery.
      // Do not let its reported scope suppress that account's real monitored
      // refresh, and do not claim the stale requested row was covered.
      return scopeIDs
    }
    // Prefer explicit fetch evidence. Older/custom strategies may omit it, so
    // fall back to the account captured for this fetch, or automatic mode's
    // effective CLI account. Row order is unrelated to credential resolution.
    if let credentialScopeID = value.credentialScopeID {
      scopeIDs.insert(credentialScopeID)
    } else if let fetchedAccount = completion.account ?? activeCLIAccounts[provider] {
      scopeIDs.insert(fetchedAccount.credentialScopeID)
    }
    if let selectedAccount = completion.account {
      // A successful refresh may rotate the credential generation. Keep the
      // pre-rotation scope excluded as the same logical account.
      scopeIDs.insert(selectedAccount.credentialScopeID)
    }
    return scopeIDs
  }

  func refresh(
    provider: UsageProvider,
    serializesProviderFetch: Bool = false
  ) async {
    // A superseded selection fetch (cancelled when the selection changed) or a
    // fetch that a switch has since started must not hit the network and
    // rotate a credential slot out from under the switch.
    guard !Task.isCancelled, !isSwitching, isProviderEnabled(provider),
          let descriptor = providers.first(where: { $0.id == provider })
    else { return }
    if providersNeedingMonitoredUsageRestore.contains(provider) {
      await reloadAccounts()
      guard !Task.isCancelled, !isSwitching, isProviderEnabled(provider) else { return }
    }
    let now = Date()
    let completion: ProviderFetchCompletion = if serializesProviderFetch {
      await coordinatedSerializedProviderFetch(
        descriptor: descriptor,
        now: now
      )
    } else {
      await selectionProviderFetch(descriptor: descriptor, now: now)
    }
    guard !Task.isCancelled,
          isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == completion.revision
    else { return }
    let coveredCredentialScopeIDs = credentialScopeIDsCovered(by: completion, provider: provider)
    apply(provider: provider, account: completion.account, result: completion.result)
    lastRefresh = Date()
    if providersNeedingMonitoredUsageRestore.remove(provider) != nil,
       !(monitoredAccounts[provider] ?? []).isEmpty {
      await refreshAccountUsage(
        for: provider,
        force: false,
        excludingCredentialScopeIDs: coveredCredentialScopeIDs
      )
    }
    await syncCapturedCopies(of: capturedCopyCandidates.filter { $0.provider == provider })
    // The fetch may have rotated a Claude token; the email label's retry key
    // is the access-token fingerprint, so this re-fetches exactly once.
    if provider == .claude {
      refreshClaudeProfiles()
    }
  }

  private func apply(
    provider: UsageProvider,
    account: ProviderAccount?,
    result: Result<ProviderFetchResult, Error>
  ) {
    switch result {
    case let .success(value):
      if let account, value.sourceKind != .mock,
         !fetchResult(value, belongsTo: account) {
        return
      }
      applySuccessfulFetch(value, provider: provider, account: account)
    case let .failure(error):
      errors[provider] = error.localizedDescription // keep any prior snapshot
      recordAccountUsageFailure(error, provider: provider, account: account)
    }
  }
}
