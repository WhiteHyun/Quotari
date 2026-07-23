import Foundation
import QuotariCore

extension UsageStore {
  /// Spawns a tracked dashboard refresh. UI and the timer go through this so
  /// `inFlightRefresh` always reflects the actually-running refresh an account
  /// switch may need to await. A second call while one is in flight coalesces
  /// through `pendingRefreshInteraction` instead of replacing the handle with a task
  /// that would return immediately via the `isRefreshing` guard — otherwise a
  /// switch could await a no-op and race the real refresh's slot write.
  func beginRefresh(
    reusesLatestAccountReload: Bool = false,
    interaction: ProviderFetchInteraction = .userInitiated
  ) {
    if case .userInitiated = interaction {
      cancelAllDelayedCredentialRefreshes()
    }
    // Don't start a fetch while a switch is rewriting a credential slot.
    guard !isSwitching else { return }
    guard inFlightRefresh == nil else {
      queueRefresh(interaction: interaction)
      return
    }
    inFlightRefresh = Task { [weak self] in
      await self?.refresh(
        clearsInFlightRefresh: true,
        reusesLatestAccountReload: reusesLatestAccountReload,
        interaction: interaction
      )
    }
  }

  func refresh() async {
    cancelAllDelayedCredentialRefreshes()
    await refresh(
      clearsInFlightRefresh: false,
      reusesLatestAccountReload: false,
      interaction: .userInitiated
    )
  }

  private func refresh(
    clearsInFlightRefresh: Bool,
    reusesLatestAccountReload: Bool,
    interaction: ProviderFetchInteraction
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
      queueRefresh(interaction: interaction)
      return
    }
    isRefreshing = true
    defer {
      isRefreshing = false
      pendingRefreshInteraction = nil
    }

    // A live stand-in can silently start pointing at a different login when
    // its CLI slot is reused; rediscover first so the timer path reconciles
    // the selection just like a manual reload.
    guard await prepareReconciledAccountsForRefresh(
      reusesLatestAccountReload: reusesLatestAccountReload
    ) else { return }
    var currentInteraction = interaction
    while true {
      // A switch can close the gate after the discovery await above, or while
      // draining a previous pass. Never begin another provider fetch inside
      // that protected write window.
      guard !isSwitching else { return }
      await performRefresh(interaction: currentInteraction)
      guard let queuedInteraction = pendingRefreshInteraction else { break }
      pendingRefreshInteraction = nil
      currentInteraction = queuedInteraction
    }
    // Self-heal email labels after a usage refresh may have rotated a token:
    // the access-token fingerprint changes, so this re-fetches exactly once.
    refreshClaudeProfiles()
  }

  private func queueRefresh(interaction: ProviderFetchInteraction) {
    switch (pendingRefreshInteraction, interaction) {
    case (.userInitiated, _), (_, .userInitiated):
      pendingRefreshInteraction = .userInitiated
    default:
      pendingRefreshInteraction = .background
    }
  }

  func startTimer(reusesLatestAccountReloadForFirstRefresh: Bool = false) {
    timerTask?.cancel()
    timerTask = Task { [weak self] in
      var reusesLatestAccountReload = reusesLatestAccountReloadForFirstRefresh
      while !Task.isCancelled {
        guard let self else { break }
        beginRefresh(
          reusesLatestAccountReload: reusesLatestAccountReload,
          interaction: .background
        )
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

  func performRefresh(interaction: ProviderFetchInteraction) async {
    let now = Date()
    var fetchedCredentialScopeIDs: [UsageProvider: Set<String>] = [:]
    await withTaskGroup(
      of: (UsageProvider, ProviderFetchCompletion).self
    ) { group in
      for descriptor in enabledProviderDescriptors
        where !isCredentialRefreshDelayed(for: descriptor.id, interaction: interaction) {
        group.addTask {
          await (
            descriptor.id,
            self.coordinatedProviderFetch(
              descriptor: descriptor,
              now: now,
              interaction: interaction
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
      for descriptor in enabledProviderDescriptors
        where delayedCredentialRefreshTasks[descriptor.id] == nil
        && !(monitoredAccounts[descriptor.id] ?? []).isEmpty {
        group.addTask {
          await self.refreshAccountUsage(
            for: descriptor.id,
            notifiesQuota: true,
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
    guard case let .success(value) = completion.result else {
      return scopeIDs
    }
    let attributedAccount: ProviderAccount?
    if let fetchedAccount = completion.account {
      guard fetchResult(value, belongsTo: fetchedAccount) else {
        // The mutable slot was replaced by an unrelated login after discovery.
        // Do not let its reported scope suppress that account's real monitored
        // refresh, and do not claim the stale requested row was covered.
        return scopeIDs
      }
      attributedAccount = fetchedAccount
    } else {
      attributedAccount = accountIdentified(by: value, provider: provider)
        ?? matchedAccount(for: value.usage, provider: provider)
    }
    // Exclude only a result that the same success path can actually store
    // under an account. An unattributed automatic result must leave the active
    // CLI row eligible for its explicit monitored-account fetch.
    guard let attributedAccount else { return scopeIDs }
    if let credentialScopeID = value.credentialScopeID {
      scopeIDs.insert(credentialScopeID)
    }
    // A successful refresh may rotate the credential generation. Keep the
    // pre-rotation scope excluded as the same logical account.
    scopeIDs.insert(attributedAccount.credentialScopeID)
    return scopeIDs
  }

  func refresh(
    provider: UsageProvider,
    serializesProviderFetch: Bool = false,
    interaction: ProviderFetchInteraction = .userInitiated,
    bypassesDelayedCredentialRefresh: Bool = false,
    drainsDelayedCredentialRefresh: Bool = true
  ) async {
    if case .userInitiated = interaction, drainsDelayedCredentialRefresh {
      await cancelDelayedCredentialRefreshAndDrainSelection(for: provider)
    }
    // A superseded selection fetch (cancelled when the selection changed) or a
    // fetch that a switch has since started must not hit the network and
    // rotate a credential slot out from under the switch.
    guard !Task.isCancelled, !isSwitching, isProviderEnabled(provider),
          bypassesDelayedCredentialRefresh
          || !isCredentialRefreshDelayed(for: provider, interaction: interaction),
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
        now: now,
        interaction: interaction
      )
    } else {
      await selectionProviderFetch(
        descriptor: descriptor,
        now: now,
        interaction: interaction
      )
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
        notifiesQuota: true,
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
      if let account, !fetchResult(value, belongsTo: account) {
        return
      }
      applySuccessfulFetch(value, provider: provider, account: account)
    case let .failure(error):
      errors[provider] = error.localizedDescription // keep any prior snapshot
      recordAccountUsageFailure(error, provider: provider, account: account)
    }
  }
}
