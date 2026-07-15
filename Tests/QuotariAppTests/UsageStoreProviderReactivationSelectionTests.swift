import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ProviderReactivationSelectionTests {
  @Test func selectionReplacingReactivationDoesNotWaitOnItsOwningDashboard() async {
    let strategy = ReactivationSelectionStrategy()
    let selected = ProviderAccount(
      provider: .codex,
      displayName: "Selected Codex",
      detail: nil,
      credentialSource: .quotariRegistry(id: "codex:replacement-selection")
    )
    let discovery = ReactivationBlockingDiscovery()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(strategy)],
      accountDiscovery: discovery,
      automaticallyCapturesDiscoveredAccounts: false,
      startsAutomatically: false
    )
    let reload = Task { await store.reloadAccounts() }
    await discovery.waitUntilStarted()
    store.automaticallyCapturingProviders.insert(.codex)

    store.beginRefresh()
    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    let reactivationRefresh = store.selectionRefreshTasks[.codex]
    store.selectAccount(selected, for: .codex)
    let selectionRefresh = store.selectionRefreshTasks[.codex]
    await discovery.release()
    await reload.value

    let started = await waitForRequestCount(strategy, atLeast: 1)
    #expect(started)
    guard started else {
      await strategy.resumeFirstRequest()
      return
    }
    await strategy.resumeFirstRequest()
    await selectionRefresh?.value
    await reactivationRefresh?.value
    await store.inFlightRefresh?.value

    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }

  private func descriptor(_ strategy: ReactivationSelectionStrategy) -> ProviderDescriptor {
    ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0.2, 0.5, 0.8),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
  }
}

private actor ReactivationBlockingDiscovery: ProviderAccountDiscovering {
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func accounts(for _: UsageProvider) async -> [ProviderAccount] {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    guard !released else { return [] }
    await withCheckedContinuation { releaseWaiters.append($0) }
    return []
  }

  func liveAccount(
    equivalentTo _: ProviderAccount,
    among _: [ProviderAccount]
  ) async -> ProviderAccount? {
    nil
  }

  func capturedCopies(among _: [ProviderAccount]) async -> [String: ProviderAccount] {
    [:]
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    released = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private actor ReactivationSelectionStrategy: ProviderFetchStrategy {
  nonisolated let id = "reactivation-selection"
  nonisolated let kind = ProviderFetchKind.api
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequests = 0
  private var concurrentRequests = 0
  private var firstRequestReleased = false
  private var firstRequestContinuation: CheckedContinuation<Void, Never>?

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    concurrentRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
    if requestCount == 1, !firstRequestReleased {
      await withCheckedContinuation { firstRequestContinuation = $0 }
    }
    concurrentRequests -= 1
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Serialized"
    )
  }

  func resumeFirstRequest() {
    firstRequestReleased = true
    firstRequestContinuation?.resume()
    firstRequestContinuation = nil
  }
}

private func waitForRequestCount(
  _ strategy: ReactivationSelectionStrategy,
  atLeast expected: Int
) async -> Bool {
  for _ in 0 ..< 100 {
    if await strategy.requestCount >= expected {
      return true
    }
    await Task.yield()
  }
  return await strategy.requestCount >= expected
}
