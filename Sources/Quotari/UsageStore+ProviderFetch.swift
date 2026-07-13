import Foundation
import QuotariCore

extension UsageStore {
  /// Tracks selection-triggered fetches as a chain. Cancellation is
  /// cooperative: an older OAuth exchange can still rotate its credential,
  /// so the newest handle must represent every superseded generation that an
  /// account switch needs to drain before touching the CLI slot.
  func enqueueSelectionRefresh(
    for provider: UsageProvider,
    waitingForProviderActivity: Bool = false
  ) {
    let previousRefresh = selectionRefreshTasks[provider]
    let dashboardRefresh = waitingForProviderActivity ? inFlightRefresh : nil
    let providerFetch = waitingForProviderActivity ? providerFetchTasks[provider]?.task : nil
    let accountUsageRefresh = waitingForProviderActivity
      ? accountUsageRefreshTasks[provider]?.task
      : nil
    let costRefresh = costTasks[provider]?.task
    previousRefresh?.cancel()
    selectionRefreshTasks[provider] = Task { [weak self] in
      await previousRefresh?.value
      await dashboardRefresh?.value
      _ = await providerFetch?.value
      await accountUsageRefresh?.value
      await costRefresh?.value
      guard !Task.isCancelled else { return }
      await self?.refresh(
        provider: provider,
        serializesProviderFetch: waitingForProviderActivity
      )
    }
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
    expectedRevision: UInt
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
      return await descriptor.fetch(
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID
      )
    }
    providerFetchTasks[provider] = ProviderFetchTask(
      generation: generation,
      task: task
    )
    let result = await task.value
    if providerFetchTasks[provider]?.generation == generation {
      providerFetchTasks[provider] = nil
    }
    return result
  }
}

struct ProviderFetchTask {
  let generation: UUID
  let task: Task<Result<ProviderFetchResult, Error>, Never>
}
