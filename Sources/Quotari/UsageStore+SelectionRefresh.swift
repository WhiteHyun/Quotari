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
    // General selection replacements do not wait on the credential drain,
    // so every generation created while it is active can safely extend it.
    // Reactivation tasks may restore monitored usage and enter the drain, so
    // they must remain independent.
    let cancellationDrainGeneration = waitingForProviderActivity
      ? nil
      : credentialRefreshDrainTasks[provider]?.generation
    let delayedRefresh = waitsForDelayedCredentialRefresh
      ? delayedCredentialRefreshTasks[provider]
      : nil
    let bypassesOwnedDelayedRefresh = delayedRefresh?.ownedSelectionTask != nil
    guard shouldEnqueueSelectionRefresh(
      waitsForDelayedCredentialRefresh: waitsForDelayedCredentialRefresh,
      delayedRefresh: delayedRefresh
    ) else { return }

    let generation = UUID()
    prepareSelectionRefresh(
      for: provider,
      generation: generation,
      waitingForProviderActivity: waitingForProviderActivity,
      delayedRefresh: delayedRefresh
    )
    let request = SelectionRefreshRequest(
      generation: generation,
      waitingForProviderActivity: waitingForProviderActivity,
      interaction: interaction,
      bypassesDelayedCredentialRefresh: bypassesDelayedCredentialRefresh
        || bypassesOwnedDelayedRefresh
        || cancellationDrainGeneration != nil
    )
    let task = makeSelectionRefreshTask(
      for: provider,
      previousRefresh: selectionRefreshTasks[provider],
      request: request
    )
    selectionRefreshTasks[provider] = task
    queueCredentialRefreshDrainReplacementIfNeeded(
      task,
      for: provider,
      drainGeneration: cancellationDrainGeneration
    )
    queueSelectionReplacementIfNeeded(
      task,
      for: provider,
      delayedRefresh: delayedRefresh,
      bypassesOwnedDelayedRefresh: bypassesOwnedDelayedRefresh
    )
  }

  private func queueCredentialRefreshDrainReplacementIfNeeded(
    _ task: Task<Void, Never>,
    for provider: UsageProvider,
    drainGeneration: UUID?
  ) {
    guard let drainGeneration,
          var drain = credentialRefreshDrainTasks[provider],
          drain.generation == drainGeneration
    else { return }
    drain.replacement = CredentialRefreshDrainReplacement(
      generation: UUID(),
      task: task
    )
    credentialRefreshDrainTasks[provider] = drain
  }

  private func shouldEnqueueSelectionRefresh(
    waitsForDelayedCredentialRefresh: Bool,
    delayedRefresh: DelayedCredentialRefreshTask?
  ) -> Bool {
    if waitsForDelayedCredentialRefresh,
       delayedRefresh != nil,
       delayedRefresh?.ownedSelectionTask == nil {
      // Rediscovery changed the account while the stabilization timer is
      // still sleeping. The eventual owner fetch snapshots the latest
      // selection, so no second generation is needed.
      return false
    }
    return true
  }

  private func prepareSelectionRefresh(
    for provider: UsageProvider,
    generation: UUID,
    waitingForProviderActivity: Bool,
    delayedRefresh: DelayedCredentialRefreshTask?
  ) {
    dashboardBlockingSelectionRefreshes[provider] = waitingForProviderActivity ? nil : generation
    if delayedRefresh == nil {
      selectionRefreshTasks[provider]?.cancel()
    } else {
      delayedRefresh?.queuedReplacementTask?.cancel()
    }
  }

  private func makeSelectionRefreshTask(
    for provider: UsageProvider,
    previousRefresh: Task<Void, Never>?,
    request: SelectionRefreshRequest
  ) -> Task<Void, Never> {
    let dashboardRefresh = request.waitingForProviderActivity ? inFlightRefresh : nil
    let providerFetch = request.waitingForProviderActivity
      ? providerFetchTasks[provider]?.task
      : nil
    let accountUsageRefresh = request.waitingForProviderActivity
      ? accountUsageRefreshTasks[provider]?.task
      : nil
    let costRefresh = costTasks[provider]?.task
    let dependencies = SelectionRefreshDependencies(
      dashboardRefresh: dashboardRefresh,
      providerFetch: providerFetch,
      accountUsageRefresh: accountUsageRefresh,
      costRefresh: costRefresh
    )
    return Task { @MainActor [weak self] in
      await self?.performSelectionRefresh(
        for: provider,
        previousRefresh: previousRefresh,
        dependencies: dependencies,
        request: request
      )
    }
  }

  private func performSelectionRefresh(
    for provider: UsageProvider,
    previousRefresh: Task<Void, Never>?,
    dependencies: SelectionRefreshDependencies,
    request: SelectionRefreshRequest
  ) async {
    defer {
      if dashboardBlockingSelectionRefreshes[provider] == request.generation {
        dashboardBlockingSelectionRefreshes[provider] = nil
      }
    }
    await previousRefresh?.value
    if request.waitingForProviderActivity, let dashboardRefresh = dependencies.dashboardRefresh {
      await waitForTaskUnlessCancelled(dashboardRefresh)
      if Task.isCancelled {
        // The dashboard may already own a child fetch. Drain it before the
        // replacement starts so credential rotations cannot overlap.
        _ = await providerFetchTasks[provider]?.task.value
        return
      }
    } else {
      await dependencies.dashboardRefresh?.value
    }
    _ = await dependencies.providerFetch?.value
    _ = await dependencies.accountUsageRefresh?.value
    await dependencies.costRefresh?.value
    guard !Task.isCancelled else { return }
    await refresh(
      provider: provider,
      serializesProviderFetch: request.waitingForProviderActivity,
      interaction: request.interaction,
      bypassesDelayedCredentialRefresh: request.bypassesDelayedCredentialRefresh,
      drainsDelayedCredentialRefresh: false
    )
  }

  private func queueSelectionReplacementIfNeeded(
    _ task: Task<Void, Never>,
    for provider: UsageProvider,
    delayedRefresh: DelayedCredentialRefreshTask?,
    bypassesOwnedDelayedRefresh: Bool
  ) {
    guard bypassesOwnedDelayedRefresh,
          var delayed = delayedCredentialRefreshTasks[provider],
          delayed.generation == delayedRefresh?.generation
    else { return }
    delayed.queuedReplacementTask = task
    delayedCredentialRefreshTasks[provider] = delayed
  }
}

private struct SelectionRefreshRequest {
  let generation: UUID
  let waitingForProviderActivity: Bool
  let interaction: ProviderFetchInteraction
  let bypassesDelayedCredentialRefresh: Bool
}

private struct SelectionRefreshDependencies {
  let dashboardRefresh: Task<Void, Never>?
  let providerFetch: Task<Result<ProviderFetchResult, Error>, Never>?
  let accountUsageRefresh: Task<AccountUsageRefreshOutcome, Never>?
  let costRefresh: Task<Void, Never>?
}

func waitForTaskUnlessCancelled(_ task: Task<Void, Never>) async {
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
