import QuotariCore

extension UsageStore {
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
    var providerAccounts = reload.accounts
    let update = await reloadedSelectionUpdate(
      provider: provider,
      reload: reload,
      accounts: &providerAccounts
    )
    let activeCLIAccount = await accountDiscovery.activeCLIAccount(
      for: provider,
      among: providerAccounts
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
    let accounts = state.accounts
    let discoveredAccounts = state.discoveredAccounts
    let credentialTransitions = state.credentialTransitions
    guard let persisted = persistedMonitoredAccounts[provider] else {
      // Missing means "not configured yet" while an explicit empty array means
      // the user chose none. Do not collapse those states before an account is
      // available, or a later first login would never become monitored.
      guard !discoveredAccounts.isEmpty else { return [] }
      let logicalAccounts = discoveredAccounts.map { capturedCopies[$0.id] ?? $0 }
      persistedMonitoredAccounts[provider] = logicalAccounts.uniquedByID()
      return discoveredAccounts
    }

    var migrated = persisted
    let visible = persisted.enumerated().compactMap { index, logicalAccount in
      if let visible = accounts.first(where: {
        $0.id == logicalAccount.id && $0.credentialScopeID == logicalAccount.credentialScopeID
      }) {
        // A capture may have succeeded after this live row was first persisted.
        // Move the durable choice to its immutable registry identity before the
        // mutable slot can be reused by another login.
        if let captured = capturedCopies[visible.id] {
          migrated[index] = captured
        }
        return visible
      }
      if let targetScopeID = credentialTransitions[logicalAccount.credentialScopeID],
         let visible = accounts.first(where: { $0.credentialScopeID == targetScopeID }) {
        // A completed OAuth refresh proves that this new credential is the
        // successor to the monitored live row. Persist its captured identity
        // when available; otherwise remember the rotated scope so a later
        // unrelated slot replacement cannot inherit monitoring.
        migrated[index] = capturedCopies[visible.id] ?? visible
        return visible
      }
      return accounts.first { capturedCopies[$0.id]?.id == logicalAccount.id }
    }.uniquedByID()
    let migratedUnique = migrated.uniquedByID()
    if migratedUnique != persisted {
      persistedMonitoredAccounts[provider] = migratedUnique
    }
    return visible
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
