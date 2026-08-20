import Foundation
import QuotariCore

extension UsageStore {
  func invalidateAccountRevision(for provider: UsageProvider) {
    accountRevisions[provider, default: 0] &+= 1
  }

  /// Serializes full-dashboard and provider-reactivation fetches until each
  /// actually exits. A revision check alone cannot undo an OAuth token-rotation
  /// side effect, so either direction must await the other before starting.
  func serializedProviderFetch(
    descriptor: ProviderDescriptor,
    now: Date,
    account: ProviderAccount?,
    capturedRegistryID: String?,
    expectedRevision: UInt,
    interaction: ProviderFetchInteraction = .background
  ) async -> Result<ProviderFetchResult, Error> {
    let provider = descriptor.id
    guard isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == expectedRevision
    else {
      return .failure(CancellationError())
    }
    let previous = providerFetchTasks[provider]?.task
    let generation = UUID()
    let fetch = lifecycleLoggedProviderFetch(
      descriptor: descriptor,
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryID,
      interaction: interaction
    )
    let task = Task<Result<ProviderFetchResult, Error>, Never> { @MainActor [weak self] in
      _ = await previous?.value
      guard let self,
            !Task.isCancelled,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == expectedRevision
      else {
        return Result.failure(CancellationError())
      }
      let result = await fetch()
      recordCompletedCredentialTransition(result, provider: provider)
      return result
    }
    providerFetchTasks[provider] = ProviderFetchTask(
      generation: generation,
      credentialScopeID: account?.credentialScopeID,
      task: task
    )
    let result = await task.value
    if providerFetchTasks[provider]?.generation == generation {
      providerFetchTasks[provider] = nil
    }
    return result
  }

  /// Establishes the account and registry-link snapshot only after any
  /// automatic capture that started first has published its rediscovery. Once
  /// this method passes that gate it registers the provider task without an
  /// intervening suspension, so a capture that starts later will drain it.
  func coordinatedProviderFetch(
    descriptor: ProviderDescriptor,
    now: Date,
    interaction: ProviderFetchInteraction
  ) async -> ProviderFetchCompletion {
    let provider = descriptor.id
    if automaticallyCapturingProviders.contains(provider) {
      await inFlightAccountReload?.value
    }
    // A dashboard that has not entered its fetch waits for the latest user
    // selection's whole queued generation, including pre-fetch dependencies.
    // It also drains an already-started independent child left behind after a
    // reactivation replaced the outer task. Either await can admit a newer
    // selection, so recheck both barriers before snapshotting the account.
    while true {
      if dashboardBlockingSelectionRefreshes[provider] != nil {
        await selectionRefreshTasks[provider]?.value
        continue
      }
      guard let selectionFetch = selectionProviderFetchTasks[provider] else { break }
      _ = await selectionFetch.task.value
      if dashboardBlockingSelectionRefreshes[provider] != nil {
        continue
      }
      if let latest = selectionProviderFetchTasks[provider],
         latest.generation != selectionFetch.generation {
        continue
      }
      break
    }
    if automaticallyCapturingProviders.contains(provider) {
      await inFlightAccountReload?.value
    }
    let account = selectedAccounts[provider]
    let capturedRegistryID = capturedRegistryIDForFetch(
      provider: provider,
      selectedAccount: account
    )
    let revision = accountRevisions[provider] ?? 0
    let result = await serializedProviderFetch(
      descriptor: descriptor,
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryID,
      expectedRevision: revision,
      interaction: interaction
    )
    return ProviderFetchCompletion(account: account, revision: revision, result: result)
  }

  /// Provider reactivation uses the serialized dashboard fetch lane, but it
  /// still has to honor an automatic capture that closed the credential gate
  /// first. Once the gate opens, snapshot and register without another await so
  /// a capture starting afterward can see and drain this task.
  func coordinatedSerializedProviderFetch(
    descriptor: ProviderDescriptor,
    now: Date,
    interaction: ProviderFetchInteraction
  ) async -> ProviderFetchCompletion {
    let provider = descriptor.id
    if automaticallyCapturingProviders.contains(provider) {
      await inFlightAccountReload?.value
    }
    let account = selectedAccounts[provider]
    let revision = accountRevisions[provider] ?? 0
    let result = await serializedProviderFetch(
      descriptor: descriptor,
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryIDForFetch(
        provider: provider,
        selectedAccount: account
      ),
      expectedRevision: revision,
      interaction: interaction
    )
    return ProviderFetchCompletion(account: account, revision: revision, result: result)
  }

  /// Selection changes intentionally supersede an older dashboard request
  /// instead of waiting for it. The outer selection generation is the barrier
  /// for dashboards that start later; this child remains independently tracked
  /// so automatic capture and account switching can drain a started rotation.
  func selectionProviderFetch(
    descriptor: ProviderDescriptor,
    now: Date,
    interaction: ProviderFetchInteraction = .userInitiated
  ) async -> ProviderFetchCompletion {
    let provider = descriptor.id
    if automaticallyCapturingProviders.contains(provider) {
      await inFlightAccountReload?.value
    }
    guard !Task.isCancelled else {
      return ProviderFetchCompletion(
        account: selectedAccounts[provider],
        revision: accountRevisions[provider] ?? 0,
        result: .failure(CancellationError())
      )
    }
    let account = selectedAccounts[provider]
    let capturedRegistryID = capturedRegistryIDForFetch(
      provider: provider,
      selectedAccount: account
    )
    let revision = accountRevisions[provider] ?? 0
    guard !isSwitching, isProviderEnabled(provider) else {
      return ProviderFetchCompletion(
        account: account,
        revision: revision,
        result: .failure(CancellationError())
      )
    }
    let generation = UUID()
    let fetch = lifecycleLoggedProviderFetch(
      descriptor: descriptor,
      now: now,
      account: account,
      capturedRegistryID: capturedRegistryID,
      interaction: interaction
    )
    let task = Task<Result<ProviderFetchResult, Error>, Never> { @MainActor [weak self] in
      let result = await fetch()
      self?.recordCompletedCredentialTransition(result, provider: provider)
      return result
    }
    selectionProviderFetchTasks[provider] = ProviderFetchTask(
      generation: generation,
      credentialScopeID: account?.credentialScopeID,
      task: task
    )
    let result = await waitForSelectionProviderFetch(
      task,
      provider: provider,
      generation: generation
    )
    return ProviderFetchCompletion(account: account, revision: revision, result: result)
  }

  private func waitForSelectionProviderFetch(
    _ task: Task<Result<ProviderFetchResult, Error>, Never>,
    provider: UsageProvider,
    generation: UUID
  ) async -> Result<ProviderFetchResult, Error> {
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      // The tracked child is intentionally unstructured so a replacement can
      // still await a non-cooperative OAuth exchange. Forward cancellation to
      // cooperative transports, but keep awaiting `value` until either kind
      // has actually stopped touching the credential slot.
      task.cancel()
    }
    if selectionProviderFetchTasks[provider]?.generation == generation {
      selectionProviderFetchTasks[provider] = nil
    }
    return result
  }

  func recordCompletedCredentialTransition(
    _ result: Result<ProviderFetchResult, Error>,
    provider: UsageProvider
  ) {
    guard automaticallyCapturesDiscoveredAccounts,
          provider == .claude,
          let transition = result.credentialTransitionEvidence
    else { return }
    for sourceScopeID in transition.sourceScopeIDs {
      completedCredentialTransitions[provider, default: [:]][sourceScopeID, default: []]
        .insert(transition.targetScopeID)
    }
  }

  private func lifecycleAccountForValidation(
    _ account: ProviderAccount?,
    provider: UsageProvider
  ) -> ProviderAccount? {
    guard let account else { return reconciledSelectionOrigins[provider] }
    return capturedEquivalents[account.id] ?? reconciledSelectionOrigins[provider] ?? account
  }

  private func lifecycleLoggedProviderFetch(
    descriptor: ProviderDescriptor,
    now: Date,
    account: ProviderAccount?,
    capturedRegistryID: String?,
    interaction: ProviderFetchInteraction
  ) -> LifecycleLoggedProviderFetch {
    LifecycleLoggedProviderFetch(
      descriptor: descriptor,
      account: account,
      lifecycleAccount: lifecycleAccountForValidation(account, provider: descriptor.id),
      capturedRegistryID: capturedRegistryID,
      interaction: interaction,
      now: now,
      logger: credentialLifecycleLogger
    )
  }

  func recordCompletedCredentialTransitions(
    _ transitions: [String: Set<String>],
    provider: UsageProvider
  ) {
    guard automaticallyCapturesDiscoveredAccounts, provider == .claude else { return }
    for (sourceScopeID, targetScopeIDs) in transitions {
      completedCredentialTransitions[provider, default: [:]][sourceScopeID, default: []]
        .formUnion(targetScopeIDs)
    }
  }
}

struct ProviderFetchTask {
  let generation: UUID
  let credentialScopeID: String?
  let task: Task<Result<ProviderFetchResult, Error>, Never>
}

struct ProviderFetchCompletion {
  let account: ProviderAccount?
  let revision: UInt
  let result: Result<ProviderFetchResult, Error>
}

struct ProviderCredentialTransitionEvidence {
  let targetScopeID: String
  let sourceScopeIDs: Set<String>
}

extension Result where Success == ProviderFetchResult, Failure == Error {
  var credentialTransitionEvidence: ProviderCredentialTransitionEvidence? {
    switch self {
    case let .success(value):
      guard let targetScopeID = value.credentialTransitionTargetScopeID,
            !value.credentialTransitionSourceScopeIDs.isEmpty
      else { return nil }
      return ProviderCredentialTransitionEvidence(
        targetScopeID: targetScopeID,
        sourceScopeIDs: value.credentialTransitionSourceScopeIDs
      )
    case let .failure(error):
      guard let transition = error as? ProviderFetchTransitionError else { return nil }
      return ProviderCredentialTransitionEvidence(
        targetScopeID: transition.credentialTransitionTargetScopeID,
        sourceScopeIDs: transition.credentialTransitionSourceScopeIDs
      )
    }
  }
}
