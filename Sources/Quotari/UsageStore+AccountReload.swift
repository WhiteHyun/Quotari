import QuotariCore

extension UsageStore {
  func beginAccountRediscovery() {
    accountRediscoveryRequest &+= 1
    startQueuedAccountRediscoveryIfNeeded()
  }

  func startQueuedAccountRediscoveryIfNeeded(allowWhileSwitching: Bool = false) {
    guard allowWhileSwitching || !isSwitching,
          inFlightAccountReload == nil,
          completedAccountRediscoveryRequest != accountRediscoveryRequest
    else { return }
    let drainableRequest = accountRediscoveryRequest
    inFlightAccountReload = Task { [weak self] in
      await self?.performQueuedAccountRediscovery(startingWith: drainableRequest)
    }
  }

  func reloadAccounts(preserving provider: UsageProvider? = nil) async {
    accountRediscoveryRequest &+= 1
    let request = accountRediscoveryRequest
    if let provider {
      accountPreservationRequests[provider] = request
    }
    startQueuedAccountRediscoveryIfNeeded()
    await waitForAccountRediscovery(request)
  }

  func reloadAccountsDuringSwitch() async {
    accountRediscoveryRequest &+= 1
    let request = accountRediscoveryRequest
    startQueuedAccountRediscoveryIfNeeded(allowWhileSwitching: true)
    await waitForAccountRediscovery(request)
  }

  private func performQueuedAccountRediscovery(startingWith drainableRequest: UInt) async {
    defer {
      inFlightAccountReload = nil
      startQueuedAccountRediscoveryIfNeeded()
    }
    var request = isSwitching ? drainableRequest : accountRediscoveryRequest
    while completedAccountRediscoveryRequest != request {
      let preservingProviders = accountPreservationProviders(through: request)
      await performAccountReload(preserving: preservingProviders)
      completeAccountPreservationRequests(preservingProviders, through: request)
      completedAccountRediscoveryRequest = request
      resumeAccountRediscoveryWaiters(through: request)
      // Once a switch closes the gate, finish only the pass that was already
      // reading. Its newer requests stay queued for the mandatory post-write
      // discovery (or for the reopened gate after that pass).
      guard !isSwitching else { return }
      request = accountRediscoveryRequest
    }
  }

  private func waitForAccountRediscovery(_ request: UInt) async {
    guard completedAccountRediscoveryRequest < request else { return }
    await withCheckedContinuation { continuation in
      accountRediscoveryWaiters.append(.init(request: request, continuation: continuation))
    }
  }

  private func resumeAccountRediscoveryWaiters(through request: UInt) {
    var pending: [AccountRediscoveryWaiter] = []
    for waiter in accountRediscoveryWaiters {
      if waiter.request <= request {
        waiter.continuation.resume()
      } else {
        pending.append(waiter)
      }
    }
    accountRediscoveryWaiters = pending
  }

  private func performAccountReload(preserving providersForLogin: Set<UsageProvider>) async {
    var result = AccountReloadResult()
    defer { automaticallyCapturingProviders.subtract(result.gatedProviders) }
    for descriptor in providers {
      let state = await reloadProviderState(for: descriptor, preserving: providersForLogin)
      result.append(state)
    }
    applyAccountReload(result)
    await finishAccountReload(syncCandidates: result.syncCandidates)
  }

  private func applyAccountReload(_ result: AccountReloadResult) {
    // Reconcile monitoring only after every provider await has completed. A
    // Settings toggle can run while this main-actor reload is suspended.
    let persistedMonitoringBeforeReconciliation = persistedMonitoredAccounts
    var nextMonitoredAccounts: [UsageProvider: [ProviderAccount]] = [:]
    for descriptor in providers {
      nextMonitoredAccounts[descriptor.id] = reloadedMonitoredAccounts(
        result.states[descriptor.id],
        capturedCopies: result.capturedCopies
      )
    }
    accounts = result.states.mapValues(\.accounts)
    providersWithDiscoveredCredentials = result.providersWithDiscoveredCredentials
    credentialDiscoveryCompleted = Set(providers.map(\.id))
    capturedEquivalents = result.capturedCopies
    activeCLIAccounts = result.activeCLIAccounts
    monitoredAccounts = nextMonitoredAccounts
    applyReloadedSelections(result.selectionUpdates)
    if persistedMonitoredAccounts != persistedMonitoringBeforeReconciliation
      || !isMonitoringConfigurationLoaded {
      persistMonitoringSelections(allowsRecovery: true)
    }
  }

  private func applyReloadedSelections(
    _ updates: [(UsageProvider, SelectionUpdate)]
  ) {
    for (provider, update) in updates {
      selectAccount(
        update.account,
        for: provider,
        standingInFor: update.origin,
        refreshInteraction: .background,
        cancelsDelayedCredentialRefresh: false,
        waitsForDelayedCredentialRefresh: true
      )
    }
  }

  func finishAccountReload(syncCandidates: [ProviderAccount]) async {
    for provider in providers.map(\.id) {
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[provider],
        origin: reconciledSelectionOrigins[provider],
        provider: provider
      )
    }
    await migrateCachedClaudeProfilesToCapturedAccounts()
    await syncCapturedCopies(of: syncCandidates)
    refreshClaudeProfiles()
    reconfigureUsageInsightsMonitoring()
  }

  func accountPreservationProviders(through request: UInt) -> Set<UsageProvider> {
    Set(accountPreservationRequests.compactMap { provider, requiredRequest in
      requiredRequest <= request ? provider : nil
    })
  }

  func completeAccountPreservationRequests(
    _ providers: Set<UsageProvider>,
    through request: UInt
  ) {
    for provider in providers
      where accountPreservationRequests[provider].map({ $0 <= request }) == true {
      accountPreservationRequests[provider] = nil
    }
  }

  func reloadProviderState(
    for descriptor: ProviderDescriptor,
    preserving providersForLogin: Set<UsageProvider> = []
  ) async -> ProviderAccountReloadState {
    let provider = descriptor.id
    synchronizeQuotaNotificationScope(
      account: selectedAccounts[provider],
      origin: reconciledSelectionOrigins[provider],
      provider: provider
    )
    let previousAccounts = accounts[provider] ?? []
    let reload = await reloadProviderAccounts(
      for: provider,
      capturesWhileDisabled: providersForLogin.contains(provider)
    )
    let activeCLIAccount = await accountDiscovery.activeCLIAccount(
      for: provider,
      among: reload.accounts
    )
    var providerAccounts = reload.accounts
    let update = await reloadedSelectionUpdate(
      provider: provider,
      reload: reload,
      accounts: &providerAccounts
    )
    reconcileAccountUsage(
      provider: provider,
      previousAccounts: previousAccounts,
      currentAccounts: providerAccounts
    )
    return ProviderAccountReloadState(
      provider: provider,
      accounts: providerAccounts,
      discoveredAccounts: reload.accounts,
      capturedCopies: reload.capturedCopies,
      credentialTransitions: reload.credentialTransitions,
      selectionUpdate: update,
      activeCLIAccount: activeCLIAccount,
      keepsCaptureGate: reload.keepsCaptureGate
    )
  }

  func reloadedMonitoredAccounts(
    _ state: ProviderAccountReloadState?,
    capturedCopies: [String: ProviderAccount]
  ) -> [ProviderAccount] {
    guard let state else { return [] }
    let provider = state.provider
    let discoveredAccounts = state.discoveredAccounts
    // Monitoring is an app-wide invariant rather than a user preference:
    // every account currently backed by discovered credentials participates in
    // quota refreshes. Selection placeholders are intentionally excluded.
    let logicalAccounts = discoveredAccounts
      .map { capturedCopies[$0.id] ?? $0 }
      .uniquedByID()
    if persistedMonitoredAccounts[provider] != logicalAccounts {
      persistedMonitoredAccounts[provider] = logicalAccounts
    }
    return discoveredAccounts.uniquedByID()
  }

  private func reloadProviderAccounts(
    for provider: UsageProvider,
    capturesWhileDisabled: Bool
  ) async -> ProviderAccountReload {
    var accounts = await accountDiscovery.accounts(for: provider)
    var capturedCopies = await accountDiscovery.capturedCopies(among: accounts)
    var selectionOrigins: [String: ProviderAccount] = [:]
    var managedCopies: [String: ProviderAccount] = [:]
    var credentialTransitions: [String: String] = [:]
    var verifiedDuplicateCredentialScopeIDs = Set<String>()
    var keepsCaptureGate = false

    // A source can be replaced between capture and the verification read. Two
    // bounded passes manage both observations without letting a continuously
    // mutating external slot keep one UI reload alive forever.
    for _ in 0 ..< 2
      where automaticallyCapturesDiscoveredAccounts
      && (capturesWhileDisabled || isProviderEnabled(provider)) {
      let capture = await automaticallyCaptureDiscoveredAccounts(
        accounts,
        excluding: capturedCopies,
        provider: provider
      )
      guard capture.attempted else { break }
      keepsCaptureGate = true
      // Duplicate proof belongs to this exact discovery snapshot. Replacing
      // the prior pass avoids hiding a source that stayed put while its former
      // canonical peer changed to another login during capture.
      verifiedDuplicateCredentialScopeIDs = capture.verifiedDuplicateCredentialScopeIDs
      selectionOrigins.merge(capture.selectionOrigins) { first, _ in first }
      managedCopies.merge(capture.managedCopies) { first, _ in first }
      credentialTransitions = mergedCredentialTransitions(
        credentialTransitions,
        capture.credentialTransitions
      )
      let previousCredentialScopes = Set(accounts.map(\.credentialScopeID))
      accounts = await accountDiscovery.accounts(for: provider)
      capturedCopies = await accountDiscovery.capturedCopies(among: accounts)
      for account in accounts {
        if let saved = managedCopies[account.credentialScopeID] {
          capturedCopies[account.id] = saved
        }
      }
      // Codex exposes durable account identity, so a failed capture can safely
      // give its newly observed slot the remaining bounded pass. Claude's
      // stable identity requires profile verification; a slot replacement
      // during that work remains an explicit "scan again" failure.
      let discoveryChanged = Set(accounts.map(\.credentialScopeID)) != previousCredentialScopes
      guard capture.didCapture || (provider == .codex && discoveryChanged) else { break }
    }
    accounts.removeAll { verifiedDuplicateCredentialScopeIDs.contains($0.credentialScopeID) }
    return ProviderAccountReload(
      accounts: accounts,
      capturedCopies: capturedCopies,
      selectionOrigins: selectionOrigins,
      credentialTransitions: credentialTransitions,
      keepsCaptureGate: keepsCaptureGate
    )
  }

  private func reloadedSelectionUpdate(
    provider: UsageProvider,
    reload: ProviderAccountReload,
    accounts: inout [ProviderAccount]
  ) async -> SelectionUpdate? {
    guard let selected = selectedAccounts[provider] else { return nil }
    let origin = reconciledSelectionOrigins[provider]
    if origin == nil, let saved = reload.selectionOrigins[selected.credentialScopeID] {
      if reload.capturedCopies[selected.id]?.id == saved.id,
         let live = accounts.first(where: { $0.id == selected.id }) {
        return SelectionUpdate(account: live, origin: saved)
      }
      return await reconciledSelection(selected, origin: saved, in: &accounts)
    }
    if origin == nil,
       let targetScopeID = reload.credentialTransitions[selected.credentialScopeID],
       let target = accounts.first(where: { $0.credentialScopeID == targetScopeID }) {
      // A completed OAuth transaction is sufficient to advance the live
      // selection even if account capture or profile lookup failed afterward.
      // Match the exact target scope so a subsequent external relogin cannot
      // inherit the old selection merely by reusing the same source id.
      return SelectionUpdate(
        account: target,
        origin: reload.capturedCopies[target.id]
      )
    }
    if origin == nil,
       let saved = reload.capturedCopies[selected.id],
       let live = accounts.first(where: { $0.id == selected.id }) {
      // Claude keychain/file rows and Codex auth-file rows keep a source-stable
      // id when the CLI slot is reused. Exact captured-copy evidence links the
      // *current* live identity to `saved`; it must not make an older selected
      // credential claim that new account. Clear the unavailable selection
      // instead of silently persisting the replacement as the user's choice.
      guard selected.credentialScopeID == live.credentialScopeID else {
        return SelectionUpdate(account: nil, origin: nil)
      }
      return SelectionUpdate(account: live, origin: saved)
    }
    return await reconciledSelection(selected, origin: origin, in: &accounts)
  }
}

private struct AccountReloadResult {
  var states: [UsageProvider: ProviderAccountReloadState] = [:]
  var providersWithDiscoveredCredentials = Set<UsageProvider>()
  var selectionUpdates: [(UsageProvider, SelectionUpdate)] = []
  var activeCLIAccounts: [UsageProvider: ProviderAccount] = [:]
  var capturedCopies: [String: ProviderAccount] = [:]
  var syncCandidates: [ProviderAccount] = []
  var gatedProviders = Set<UsageProvider>()

  mutating func append(_ state: ProviderAccountReloadState) {
    if state.keepsCaptureGate {
      gatedProviders.insert(state.provider)
    }
    if !state.accounts.isEmpty {
      providersWithDiscoveredCredentials.insert(state.provider)
    }
    if let selectionUpdate = state.selectionUpdate {
      selectionUpdates.append((state.provider, selectionUpdate))
    }
    if let activeCLIAccount = state.activeCLIAccount {
      activeCLIAccounts[state.provider] = activeCLIAccount
    }
    capturedCopies.merge(state.capturedCopies) { current, _ in current }
    syncCandidates += state.accounts.filter { state.capturedCopies.keys.contains($0.id) }
    states[state.provider] = state
  }
}

struct ProviderAccountReloadState {
  var provider: UsageProvider
  var accounts: [ProviderAccount]
  var discoveredAccounts: [ProviderAccount]
  var capturedCopies: [String: ProviderAccount]
  var credentialTransitions: [String: String]
  var selectionUpdate: SelectionUpdate?
  var activeCLIAccount: ProviderAccount?
  var keepsCaptureGate: Bool
}

private extension [ProviderAccount] {
  func uniquedByID() -> [ProviderAccount] {
    var ids = Set<String>()
    return filter { ids.insert($0.id).inserted }
  }
}

private struct ProviderAccountReload {
  var accounts: [ProviderAccount]
  var capturedCopies: [String: ProviderAccount]
  var selectionOrigins: [String: ProviderAccount]
  var credentialTransitions: [String: String]
  var keepsCaptureGate: Bool
}
