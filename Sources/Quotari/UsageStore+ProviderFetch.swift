import Foundation
import QuotariCore

extension UsageStore {
  /// Tracks selection-triggered fetches as a chain. Cancellation is
  /// cooperative: an older OAuth exchange can still rotate its credential,
  /// so the newest handle must represent every superseded generation that an
  /// account switch needs to drain before touching the CLI slot.
  func enqueueSelectionRefresh(
    for provider: UsageProvider,
    waitingForProviderActivity: Bool = false,
    interaction: ProviderFetchInteraction = .userInitiated,
    cancelsDelayedCredentialRefresh: Bool = true,
    bypassesDelayedCredentialRefresh: Bool = false,
    waitsForDelayedCredentialRefresh: Bool = false
  ) {
    if cancelsDelayedCredentialRefresh {
      cancelDelayedCredentialRefresh(for: provider)
    }
    let delayedRefresh = waitsForDelayedCredentialRefresh
      ? delayedCredentialRefreshTasks[provider]
      : nil
    let bypassesOwnedDelayedRefresh = delayedRefresh?.ownedSelectionTask != nil
    if waitsForDelayedCredentialRefresh,
       delayedRefresh != nil,
       delayedRefresh?.ownedSelectionTask == nil {
      // Rediscovery changed the account while the stabilization timer is
      // still sleeping. The eventual owner fetch snapshots the latest
      // selection, so no second generation is needed.
      return
    }
    let previousRefresh = selectionRefreshTasks[provider]
    let dashboardRefresh = waitingForProviderActivity ? inFlightRefresh : nil
    let providerFetch = waitingForProviderActivity ? providerFetchTasks[provider]?.task : nil
    let accountUsageRefresh = waitingForProviderActivity
      ? accountUsageRefreshTasks[provider]?.task
      : nil
    let costRefresh = costTasks[provider]?.task
    let generation = UUID()
    if waitingForProviderActivity {
      dashboardBlockingSelectionRefreshes[provider] = nil
    } else {
      dashboardBlockingSelectionRefreshes[provider] = generation
    }
    if delayedRefresh == nil {
      previousRefresh?.cancel()
    } else if let queuedReplacement = delayedRefresh?.queuedReplacementTask {
      queuedReplacement.cancel()
    }
    let task = Task { @MainActor [weak self] in
      defer {
        if self?.dashboardBlockingSelectionRefreshes[provider] == generation {
          self?.dashboardBlockingSelectionRefreshes[provider] = nil
        }
      }
      await previousRefresh?.value
      if waitingForProviderActivity, let dashboardRefresh {
        await waitForTaskUnlessCancelled(dashboardRefresh)
        if Task.isCancelled {
          // If the dashboard passed its selection barrier before this
          // reactivation was replaced, it may already own a provider fetch.
          // Drain that child before letting the replacement selection start;
          // otherwise returning early here would trade the deadlock for two
          // concurrent credential rotations.
          _ = await self?.providerFetchTasks[provider]?.task.value
          return
        }
      } else {
        await dashboardRefresh?.value
      }
      _ = await providerFetch?.value
      _ = await accountUsageRefresh?.value
      await costRefresh?.value
      guard !Task.isCancelled else { return }
      await self?.refresh(
        provider: provider,
        serializesProviderFetch: waitingForProviderActivity,
        interaction: interaction,
        bypassesDelayedCredentialRefresh: bypassesDelayedCredentialRefresh
          || bypassesOwnedDelayedRefresh
      )
    }
    selectionRefreshTasks[provider] = task
    if bypassesOwnedDelayedRefresh,
       var delayed = delayedCredentialRefreshTasks[provider],
       delayed.generation == delayedRefresh?.generation {
      delayed.queuedReplacementTask = task
      delayedCredentialRefreshTasks[provider] = delayed
    }
  }

  /// Login and account switching can replace Claude Code's rotating OAuth
  /// grant. Waiting briefly avoids immediately racing another Claude process
  /// that is still persisting the same credential transition.
  func enqueuePostCredentialRefresh(for provider: UsageProvider) {
    guard provider == .claude else {
      enqueueSelectionRefresh(for: provider)
      return
    }
    cancelDelayedCredentialRefresh(for: provider)
    // Login/switch rediscovery may have selected the new live row while the
    // credential gate was still closed. Supersede that eager selection task;
    // the delayed replacement will retain and drain it as its predecessor.
    selectionRefreshTasks[provider]?.cancel()
    let delay = postCredentialRefreshDelay
    let sleep = postCredentialRefreshSleep
    let generation = UUID()
    let task = Task { @MainActor [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard let self, !Task.isCancelled,
            delayedCredentialRefreshTasks[provider]?.generation == generation
      else { return }
      guard isProviderEnabled(provider) else { return }
      enqueueSelectionRefresh(
        for: provider,
        interaction: .background,
        cancelsDelayedCredentialRefresh: false,
        bypassesDelayedCredentialRefresh: true
      )
      let refresh = selectionRefreshTasks[provider]
      if var delayed = delayedCredentialRefreshTasks[provider],
         delayed.generation == generation {
        delayed.ownedSelectionTask = refresh
        delayedCredentialRefreshTasks[provider] = delayed
      }
      await refresh?.value
      // Rediscovery can append a replacement while the owner is fetching.
      // Keep the gate closed until the latest queued generation also exits;
      // replacements already drain their predecessor and deliberately do not
      // wait on this wrapper, avoiding a cycle.
      while !Task.isCancelled,
            delayedCredentialRefreshTasks[provider]?.generation == generation,
            dashboardBlockingSelectionRefreshes[provider] != nil {
        await selectionRefreshTasks[provider]?.value
      }
      if delayedCredentialRefreshTasks[provider]?.generation == generation {
        delayedCredentialRefreshTasks[provider] = nil
      }
    }
    delayedCredentialRefreshTasks[provider] = DelayedCredentialRefreshTask(
      generation: generation,
      task: task,
      ownedSelectionTask: nil,
      queuedReplacementTask: nil
    )
  }

  func cancelDelayedCredentialRefresh(for provider: UsageProvider) {
    guard let delayed = delayedCredentialRefreshTasks.removeValue(forKey: provider) else { return }
    delayed.task.cancel()
    delayed.ownedSelectionTask?.cancel()
    delayed.queuedReplacementTask?.cancel()
    selectionRefreshTasks[provider]?.cancel()
  }

  func cancelDelayedCredentialRefreshAndDrainSelection(for provider: UsageProvider) async {
    let currentSelection = selectionRefreshTasks[provider]
    cancelDelayedCredentialRefresh(for: provider)
    await currentSelection?.value
  }

  func cancelAllDelayedCredentialRefreshes() {
    let delayed = delayedCredentialRefreshTasks
    delayedCredentialRefreshTasks.removeAll()
    delayed.forEach { provider, refresh in
      refresh.task.cancel()
      refresh.ownedSelectionTask?.cancel()
      refresh.queuedReplacementTask?.cancel()
      selectionRefreshTasks[provider]?.cancel()
    }
  }

  func isCredentialRefreshDelayed(
    for provider: UsageProvider,
    interaction: ProviderFetchInteraction
  ) -> Bool {
    guard case .background = interaction else { return false }
    return delayedCredentialRefreshTasks[provider] != nil
  }

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
    let task = Task<Result<ProviderFetchResult, Error>, Never> { @MainActor [weak self] in
      _ = await previous?.value
      guard let self,
            !Task.isCancelled,
            isProviderEnabled(provider),
            (accountRevisions[provider] ?? 0) == expectedRevision
      else {
        return Result.failure(CancellationError())
      }
      let result = await descriptor.fetch(
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID,
        interaction: interaction
      )
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
    let task = Task<Result<ProviderFetchResult, Error>, Never> { @MainActor [weak self] in
      let result = await descriptor.fetch(
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID,
        interaction: interaction
      )
      self?.recordCompletedCredentialTransition(result, provider: provider)
      return result
    }
    selectionProviderFetchTasks[provider] = ProviderFetchTask(
      generation: generation,
      credentialScopeID: account?.credentialScopeID,
      task: task
    )
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
    return ProviderFetchCompletion(account: account, revision: revision, result: result)
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

private func waitForTaskUnlessCancelled(_ task: Task<Void, Never>) async {
  guard !Task.isCancelled else { return }
  let waiter = CancellationAwareTaskWaiter()
  await withTaskCancellationHandler {
    await withCheckedContinuation { continuation in
      waiter.register(continuation)
      Task {
        await task.value
        waiter.finish()
      }
    }
  } onCancel: {
    waiter.finish()
  }
}

private final class CancellationAwareTaskWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var isFinished = false

  func register(_ continuation: CheckedContinuation<Void, Never>) {
    let resumesImmediately = lock.withLock {
      if isFinished {
        return true
      }
      self.continuation = continuation
      return false
    }
    if resumesImmediately {
      continuation.resume()
    }
  }

  func finish() {
    let continuation = lock.withLock {
      guard !isFinished else { return nil as CheckedContinuation<Void, Never>? }
      isFinished = true
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume()
  }
}
