import Foundation
@testable import QuotariCore
import Testing

struct CodexTokenRefreshCoordinatorTests {
  @Test func concurrentCallersShareOneTransaction() async {
    let coordinator = CodexTokenRefreshCoordinator()
    let counter = CallCounter()
    let operation: @Sendable () async -> CodexCredentials = {
      await counter.increment()
      try? await Task.sleep(for: .milliseconds(100))
      return CodexCredentials(accessToken: "fresh", accountID: nil)
    }

    async let first = coordinator.resolve(key: "codex:acct-1#ref-1", operation: operation)
    async let second = coordinator.resolve(key: "codex:acct-1#ref-1", operation: operation)
    let outcomes = await [first, second]

    #expect(outcomes.map(\.accessToken) == ["fresh", "fresh"])
    #expect(await counter.count == 1)
  }

  @Test func distinctTokenGenerationsResolveIndependently() async {
    let coordinator = CodexTokenRefreshCoordinator()
    let counter = CallCounter()
    let operation: @Sendable () async -> CodexCredentials = {
      await counter.increment()
      try? await Task.sleep(for: .milliseconds(50))
      return CodexCredentials(accessToken: "fresh", accountID: nil)
    }

    // Same saved account, different refresh-token generation: never share.
    async let first = coordinator.resolve(key: "codex:acct-1#ref-1", operation: operation)
    async let second = coordinator.resolve(key: "codex:acct-1#ref-2", operation: operation)
    _ = await [first, second]

    #expect(await counter.count == 2)
  }

  @Test func takingAnUnpersistedGrantRemovesIt() async {
    let coordinator = CodexTokenRefreshCoordinator()
    let pending = CodexPendingGrant(
      grant: CodexTokenGrant(accessToken: "new-tok"),
      previousAccessToken: "old-tok",
      consumedRefreshToken: "old-ref"
    )

    await coordinator.rememberUnpersisted(pending, registryID: "codex:acct-1")

    #expect(await coordinator.takeUnpersisted(registryID: "codex:acct-1") == pending)
    #expect(await coordinator.takeUnpersisted(registryID: "codex:acct-1") == nil)
  }

  private actor CallCounter {
    private(set) var count = 0
    func increment() {
      count += 1
    }
  }
}
