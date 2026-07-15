import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreSelectionCancellationTests {
  @Test func supersedingASelectionCancelsItsCooperativeProviderFetch() async {
    let strategy = SupersededSelectionStrategy()
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
    let first = selectionAccount(name: "First", path: "/tmp/first/auth.json")
    let second = selectionAccount(name: "Second", path: "/tmp/second/auth.json")

    store.selectAccount(first, for: .codex)
    await strategy.waitUntilFirstRequestStarts()
    store.selectAccount(second, for: .codex)
    await store.selectionRefreshTasks[.codex]?.value

    #expect(await strategy.firstRequestWasCancelled)
    #expect(await strategy.requestedAccountIDs == [first.id, second.id])
  }

  private func selectionAccount(name: String, path: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: "Test",
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: name
    )
  }
}

private actor SupersededSelectionStrategy: ProviderFetchStrategy {
  nonisolated let id = "superseded-selection"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var firstRequestWasCancelled = false
  private(set) var requestedAccountIDs: [String] = []
  private var firstRequestStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestedAccountIDs.append(context.account?.id ?? "automatic")
    if requestedAccountIDs.count == 1 {
      firstRequestStarted = true
      startWaiters.forEach { $0.resume() }
      startWaiters.removeAll()
      do {
        try await Task.sleep(for: .seconds(1))
      } catch is CancellationError {
        firstRequestWasCancelled = true
        throw CancellationError()
      }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        account: context.account?.displayName,
        updatedAt: context.now
      ),
      sourceLabel: "Selection"
    )
  }

  func waitUntilFirstRequestStarts() async {
    guard !firstRequestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }
}
