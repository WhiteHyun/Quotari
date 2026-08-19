import Foundation
import QuotariCore

extension UsageStore {
  /// Login and account switching can replace Claude Code's rotating OAuth
  /// grant. Waiting briefly avoids immediately racing another Claude process
  /// that is still persisting the same credential transition.
  func enqueuePostCredentialRefresh(for provider: UsageProvider) {
    let lifecycleAccount = postSwitchLifecycleAccount(for: provider)
    guard provider == .claude else {
      enqueueImmediatePostCredentialRefresh(for: provider, lifecycleAccount: lifecycleAccount)
      return
    }
    enqueueDelayedPostCredentialRefresh(for: provider, lifecycleAccount: lifecycleAccount)
  }

  private func enqueueDelayedPostCredentialRefresh(
    for provider: UsageProvider,
    lifecycleAccount: ProviderAccount?
  ) {
    recordPostSwitchRefresh(
      .postSwitchRefreshScheduled,
      provider: provider,
      account: lifecycleAccount,
      reason: .delayedAfterSwitch
    )
    preparePostSwitchRefresh(for: provider)
    let (delay, sleep) = (postCredentialRefreshDelay, postCredentialRefreshSleep)
    let generation = UUID()
    let task = makeDelayedPostCredentialRefreshTask(
      provider: provider,
      lifecycleAccount: lifecycleAccount,
      generation: generation,
      delay: delay,
      sleep: sleep
    )
    delayedCredentialRefreshTasks[provider] = DelayedCredentialRefreshTask(
      generation: generation,
      task: task,
      ownedSelectionTask: nil,
      queuedReplacementTask: nil
    )
  }

  private func makeDelayedPostCredentialRefreshTask(
    provider: UsageProvider,
    lifecycleAccount: ProviderAccount?,
    generation: UUID,
    delay: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      do {
        try await sleep(delay)
      } catch {
        self?.recordPostSwitchRefresh(
          .postSwitchRefreshCancelled,
          provider: provider,
          account: lifecycleAccount,
          reason: .delayedAfterSwitch,
          failure: .cancelled
        )
        return
      }
      await self?.runDelayedPostCredentialRefresh(
        provider: provider,
        lifecycleAccount: lifecycleAccount,
        generation: generation
      )
    }
  }

  private func runDelayedPostCredentialRefresh(
    provider: UsageProvider,
    lifecycleAccount: ProviderAccount?,
    generation: UUID
  ) async {
    guard !Task.isCancelled,
          delayedCredentialRefreshTasks[provider]?.generation == generation,
          isProviderEnabled(provider)
    else { return }
    recordPostSwitchRefresh(
      .postSwitchRefreshStarted,
      provider: provider,
      account: lifecycleAccount,
      reason: .delayedAfterSwitch
    )
    enqueueSelectionRefresh(
      for: provider,
      interaction: .userInitiated,
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
    // Keep the gate closed until the latest queued generation also exits.
    while !Task.isCancelled,
          delayedCredentialRefreshTasks[provider]?.generation == generation,
          dashboardBlockingSelectionRefreshes[provider] != nil {
      await selectionRefreshTasks[provider]?.value
    }
    let ownsGeneration = delayedCredentialRefreshTasks[provider]?.generation == generation
    if ownsGeneration {
      delayedCredentialRefreshTasks[provider] = nil
    }
    let wasCancelled = Task.isCancelled || !ownsGeneration || refresh?.isCancelled == true
    recordPostSwitchRefresh(
      wasCancelled ? .postSwitchRefreshCancelled : .postSwitchRefreshCompleted,
      provider: provider,
      account: lifecycleAccount,
      reason: .delayedAfterSwitch,
      failure: wasCancelled ? .cancelled : nil
    )
  }

  private func enqueueImmediatePostCredentialRefresh(
    for provider: UsageProvider,
    lifecycleAccount: ProviderAccount?
  ) {
    recordPostSwitchRefresh(
      .postSwitchRefreshScheduled,
      provider: provider,
      account: lifecycleAccount,
      reason: .immediateAfterSwitch
    )
    guard let refresh = enqueueSelectionRefresh(for: provider) else {
      recordPostSwitchRefresh(
        .postSwitchRefreshCancelled,
        provider: provider,
        account: lifecycleAccount,
        reason: .immediateAfterSwitch,
        failure: .cancelled
      )
      return
    }
    recordPostSwitchRefresh(
      .postSwitchRefreshStarted,
      provider: provider,
      account: lifecycleAccount,
      reason: .immediateAfterSwitch
    )
    observeImmediatePostSwitchRefresh(
      refresh,
      provider: provider,
      lifecycleAccount: lifecycleAccount
    )
  }

  private func observeImmediatePostSwitchRefresh(
    _ refresh: Task<Void, Never>,
    provider: UsageProvider,
    lifecycleAccount: ProviderAccount?
  ) {
    Task { @MainActor [weak self] in
      await refresh.value
      self?.recordPostSwitchRefresh(
        refresh.isCancelled ? .postSwitchRefreshCancelled : .postSwitchRefreshCompleted,
        provider: provider,
        account: lifecycleAccount,
        reason: .immediateAfterSwitch,
        failure: refresh.isCancelled ? .cancelled : nil
      )
    }
  }

  private func recordPostSwitchRefresh(
    _ kind: CredentialLifecycleEvent.Kind,
    provider: UsageProvider,
    account: ProviderAccount?,
    reason: CredentialLifecycleEvent.Reason? = nil,
    failure: CredentialLifecycleEvent.Failure? = nil
  ) {
    credentialLifecycleLogger.record(
      kind,
      provider: provider,
      account: account,
      interaction: .userInitiated,
      reason: reason,
      failure: failure
    )
  }

  private func postSwitchLifecycleAccount(for provider: UsageProvider) -> ProviderAccount? {
    reconciledSelectionOrigins[provider] ?? selectedAccounts[provider]
  }

  private func preparePostSwitchRefresh(for provider: UsageProvider) {
    cancelDelayedCredentialRefresh(for: provider)
    // Rediscovery may have selected the new live row while the gate was closed.
    // Supersede that eager task; the delayed replacement retains and drains it.
    selectionRefreshTasks[provider]?.cancel()
  }

  func cancelDelayedCredentialRefresh(for provider: UsageProvider) {
    guard let delayed = delayedCredentialRefreshTasks.removeValue(forKey: provider) else { return }
    let currentSelection = selectionRefreshTasks[provider]
    delayed.task.cancel()
    delayed.ownedSelectionTask?.cancel()
    delayed.queuedReplacementTask?.cancel()
    currentSelection?.cancel()
    publishCredentialRefreshDrain(for: provider, currentSelection: currentSelection)
  }

  func cancelDelayedCredentialRefreshAndDrainSelection(for provider: UsageProvider) async {
    let currentSelection = selectionRefreshTasks[provider]
    cancelDelayedCredentialRefresh(for: provider)
    publishCredentialRefreshDrain(for: provider, currentSelection: currentSelection)
    await credentialRefreshDrainTasks[provider]?.task.value
  }

  private func publishCredentialRefreshDrain(
    for provider: UsageProvider,
    currentSelection: Task<Void, Never>?
  ) {
    guard let currentSelection else { return }
    let previousDrain = credentialRefreshDrainTasks[provider]?.task
    let generation = UUID()
    let task = Task { @MainActor [weak self] in
      await previousDrain?.value
      await currentSelection.value
      while let drain = self?.credentialRefreshDrainTasks[provider],
            drain.generation == generation,
            let replacement = drain.replacement {
        await replacement.task.value
        guard self?.credentialRefreshDrainTasks[provider]?.replacement?.generation
          != replacement.generation
        else { break }
      }
      guard self?.credentialRefreshDrainTasks[provider]?.generation == generation else { return }
      self?.credentialRefreshDrainTasks[provider] = nil
    }
    credentialRefreshDrainTasks[provider] = CredentialRefreshDrainTask(
      generation: generation,
      task: task,
      replacement: nil
    )
  }

  func waitForDelayedCredentialRefreshAndDrainSelection(for provider: UsageProvider) async {
    while !Task.isCancelled {
      if let delayedRefresh = delayedCredentialRefreshTasks[provider] {
        await waitForTaskUnlessCancelled(delayedRefresh.task)
        continue
      }
      if let drain = credentialRefreshDrainTasks[provider] {
        await waitForTaskUnlessCancelled(drain.task)
        continue
      }
      return
    }
  }

  func cancelAllDelayedCredentialRefreshes() {
    for provider in Array(delayedCredentialRefreshTasks.keys) {
      cancelDelayedCredentialRefresh(for: provider)
    }
  }

  func isCredentialRefreshDelayed(
    for provider: UsageProvider,
    interaction: ProviderFetchInteraction
  ) -> Bool {
    guard case .background = interaction else { return false }
    return delayedCredentialRefreshTasks[provider] != nil
  }
}

struct DelayedCredentialRefreshTask {
  let generation: UUID
  let task: Task<Void, Never>
  var ownedSelectionTask: Task<Void, Never>?
  var queuedReplacementTask: Task<Void, Never>?
}

struct CredentialRefreshDrainTask {
  let generation: UUID
  let task: Task<Void, Never>
  var replacement: CredentialRefreshDrainReplacement?
}

struct CredentialRefreshDrainReplacement {
  let generation: UUID
  let task: Task<Void, Never>
}
