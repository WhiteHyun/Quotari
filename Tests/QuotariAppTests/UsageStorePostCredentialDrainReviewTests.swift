@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct PostCredentialDrainReviewTests {
  @Test func reactivationDoesNotBecomeOwnedByAnOlderDrain() async {
    let strategy = StepwisePostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let selected = liveClaudeAccount(credentialIdentity: "reactivation")
    let monitored = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:reactivation")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [stepwisePostCredentialDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [selected, monitored]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [monitored]
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts(count: 1)

    store.setProviderEnabled(.claude, enabled: false)
    store.setProviderEnabled(.claude, enabled: true)
    await strategy.resumeNext()
    guard await waitForRequestCount(2, strategy: strategy) else {
      #expect(Bool(false), "Reactivation provider fetch did not start")
      return
    }
    await strategy.resumeNext()
    guard await waitForRequestCount(3, strategy: strategy) else {
      #expect(Bool(false), "Reactivation monitored restore did not start")
      return
    }
    await strategy.resumeNext()
    guard await waitForCompletedRequestCount(3, strategy: strategy) else {
      #expect(Bool(false), "Reactivation monitored restore did not complete")
      return
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }

    #expect(store.credentialRefreshDrainTasks[.claude] == nil)
  }

  private func waitForRequestCount(
    _ count: Int,
    strategy: StepwisePostCredentialUsageStrategy
  ) async -> Bool {
    for _ in 0 ..< 100 {
      if await strategy.requestCount >= count {
        return true
      }
      await Task.yield()
    }
    return false
  }

  private func waitForCompletedRequestCount(
    _ count: Int,
    strategy: StepwisePostCredentialUsageStrategy
  ) async -> Bool {
    for _ in 0 ..< 100 {
      if await strategy.completedRequestCount >= count {
        return true
      }
      await Task.yield()
    }
    return false
  }
}
