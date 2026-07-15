import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreSelectionDashboardRaceTests {
  @Test func dashboardRechecksSelectionQueuedWhileDrainingAnOlderChild() async throws {
    let strategy = QueuedSelectionRaceStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0.2, 0.5, 0.8),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      startsAutomatically: false
    )
    let first = account(name: "First", registryID: "codex:first")
    let second = account(name: "Second", registryID: "codex:second")

    store.selectAccount(first, for: .codex)
    await strategy.waitUntilRequestCount(1)
    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    let dashboardRefresh = Task { await store.refresh() }
    while !store.isRefreshing {
      await Task.yield()
    }
    for _ in 0 ..< 5 {
      await Task.yield()
    }

    store.selectAccount(second, for: .codex)
    let selectionRefresh = store.selectionRefreshTasks[.codex]
    await strategy.resumeRequest(1)
    await strategy.waitUntilRequestCount(2)
    try await Task.sleep(for: .milliseconds(20))

    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
    await strategy.resumeRequest(2)
    await selectionRefresh?.value
    await dashboardRefresh.value

    #expect(await strategy.requestCount == 3)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }

  private func account(name: String, registryID: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: nil,
      credentialSource: .quotariRegistry(id: registryID)
    )
  }
}

private actor QueuedSelectionRaceStrategy: ProviderFetchStrategy {
  nonisolated let id = "queued-selection-race"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequests = 0
  private var concurrentRequests = 0
  private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var requestContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    let ordinal = requestCount
    concurrentRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
    resumeCountWaiters()
    if ordinal <= 2 {
      await withCheckedContinuation { requestContinuations[ordinal] = $0 }
    }
    concurrentRequests -= 1
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Queued selection"
    )
  }

  func waitUntilRequestCount(_ expected: Int) async {
    guard requestCount < expected else { return }
    await withCheckedContinuation { countWaiters.append((expected, $0)) }
  }

  func resumeRequest(_ ordinal: Int) {
    requestContinuations.removeValue(forKey: ordinal)?.resume()
  }

  private func resumeCountWaiters() {
    var pending: [(Int, CheckedContinuation<Void, Never>)] = []
    for (expected, continuation) in countWaiters {
      if requestCount >= expected {
        continuation.resume()
      } else {
        pending.append((expected, continuation))
      }
    }
    countWaiters = pending
  }
}
