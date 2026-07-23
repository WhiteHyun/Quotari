import Foundation
import QuotariCore

extension UsageStore {
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
      // Direct cancellation paths synchronously enqueue a replacement after
      // publishing this marker. Drain that latest generation as well.
      await self?.selectionRefreshTasks[provider]?.value
      guard self?.credentialRefreshDrainTasks[provider]?.generation == generation else { return }
      self?.credentialRefreshDrainTasks[provider] = nil
    }
    credentialRefreshDrainTasks[provider] = CredentialRefreshDrainTask(
      generation: generation,
      task: task
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
}
