import Foundation
import QuotariCore

extension UsageStore {
  func prepareReconciledAccountsForRefresh() async -> Bool {
    guard !reconciledSelectionOrigins.isEmpty else { return true }
    guard !isSwitching else {
      // The switch already owes a post-write discovery. Queue this request
      // without making the refresh being drained wait behind its own gate.
      beginAccountRediscovery()
      return false
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
    await withTaskGroup(
      of: (UsageProvider, ProviderAccount?, UInt, Result<ProviderFetchResult, Error>).self
    ) { group in
      for descriptor in enabledProviderDescriptors {
        let account = selectedAccounts[descriptor.id]
        let capturedRegistryID = capturedRegistryIDForFetch(
          provider: descriptor.id,
          selectedAccount: account
        )
        let revision = accountRevisions[descriptor.id] ?? 0
        group.addTask {
          await (
            descriptor.id,
            account,
            revision,
            self.serializedProviderFetch(
              descriptor: descriptor,
              now: now,
              account: account,
              capturedRegistryID: capturedRegistryID,
              expectedRevision: revision
            )
          )
        }
      }
      for await (provider, account, revision, result) in group {
        guard isProviderEnabled(provider),
              (accountRevisions[provider] ?? 0) == revision
        else { continue }
        apply(provider: provider, account: account, result: result)
      }
    }
    lastRefresh = Date()
    // Hidden saved copies must track live-token rotations between account
    // reloads too — a slot swapped right after a rotation would otherwise
    // strand the copy on a consumed refresh token.
    await syncCapturedCopies(of: capturedCopyCandidates.filter { isProviderEnabled($0.provider) })
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
    let account = selectedAccounts[provider]
    let capturedRegistryID = capturedRegistryIDForFetch(
      provider: provider,
      selectedAccount: account
    )
    let revision = accountRevisions[provider] ?? 0
    let now = Date()
    let result: Result<ProviderFetchResult, Error> = if serializesProviderFetch {
      await serializedProviderFetch(
        descriptor: descriptor,
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID,
        expectedRevision: revision
      )
    } else {
      await descriptor.fetch(
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID
      )
    }
    guard !Task.isCancelled,
          isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == revision
    else { return }
    apply(provider: provider, account: account, result: result)
    lastRefresh = Date()
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
      applySuccessfulFetch(value, provider: provider, account: account)
    case let .failure(error):
      errors[provider] = error.localizedDescription // keep any prior snapshot
      recordAccountUsageFailure(error, provider: provider, account: account)
    }
  }
}
