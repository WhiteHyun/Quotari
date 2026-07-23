@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct PostCredentialReviewTests {
  @Test func directDelayCancellationKeepsReplacementSelectionGated() async {
    let strategy = StepwisePostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let account = liveClaudeAccount(credentialIdentity: "direct-cancel")
    let store = UsageStore.isolatedForTesting(
      providers: [stepwisePostCredentialDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [account]
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts(count: 1)

    store.enqueueSelectionRefresh(for: .claude)
    let accountRefresh = Task {
      await store.refreshAccountUsage(for: account, force: true)
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 1)

    await strategy.resumeNext()
    await strategy.waitUntilRequestStarts(count: 2)
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 2)

    await strategy.resumeNext()
    await strategy.waitUntilRequestStarts(count: 3)
    await strategy.resumeNext()
    await accountRefresh.value
  }

  @Test func backgroundAccountUsageWaitsForCanceledSelectionDrain() async {
    let strategy = StepwisePostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let account = liveClaudeAccount(credentialIdentity: "draining")
    let store = UsageStore.isolatedForTesting(
      providers: [stepwisePostCredentialDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [account]
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts(count: 1)

    let manualRefresh = Task {
      await store.refresh(provider: .claude, interaction: .userInitiated)
    }
    let accountRefresh = Task {
      await store.refreshAccountUsage(for: account, force: true)
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 1)

    await strategy.resumeNext()
    await strategy.waitUntilRequestStarts(count: 2)
    await strategy.resumeNext()
    await strategy.waitUntilRequestStarts(count: 3)
    await strategy.resumeNext()
    await manualRefresh.value
    await accountRefresh.value
  }

  @Test func delayedCredentialFetchPreservesUserInitiatedInteraction() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let account = liveClaudeAccount(credentialIdentity: "interaction")
    let store = UsageStore.isolatedForTesting(
      providers: [countingClaudeDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value

    #expect(await strategy.interactions == [.userInitiated])
  }

  @Test func accountUsageWaitsForEverySupersedingDelay() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let monitored = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:superseding-delay")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [countingClaudeDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [monitored]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [monitored]

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested(count: 1)
    let accountRefresh = Task {
      await store.refreshAccountUsage(for: monitored, force: true)
    }
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested(count: 2)
    await delay.resumeNext()
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 0)

    await delay.resumeNext()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await accountRefresh.value
    #expect(await strategy.requestCount == 2)
  }

  @Test func delayedOwnerBypassesItsOwnMonitoredRestoreWait() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let monitored = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:owner-restore")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [countingClaudeDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [monitored]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [monitored]
    store.providersNeedingMonitoredUsageRestore.insert(.claude)
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()

    var completedRestore = false
    for _ in 0 ..< 100 {
      if await strategy.requestCount >= 2 {
        completedRestore = true
        break
      }
      await Task.yield()
    }
    #expect(completedRestore)
    guard completedRestore else {
      store.cancelDelayedCredentialRefresh(for: .claude)
      return
    }
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
  }

  @Test func accountUsageOpenedDuringDelayRunsAfterDelayedRefresh() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let selected = liveClaudeAccount(credentialIdentity: "selected")
    let monitored = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:monitored")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [countingClaudeDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [selected, monitored]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [monitored]

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    let accountRefresh = Task {
      await store.refreshAccountUsage(for: monitored, force: true)
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 0)

    await delay.resumeAll()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await accountRefresh.value
    #expect(await strategy.requestCount == 2)
  }

  @Test func dashboardKeepsDelayedProviderExcludedAfterManualRefreshStarts() async {
    let claudeStrategy = StepwisePostCredentialUsageStrategy()
    let codexStrategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let account = liveClaudeAccount(credentialIdentity: "current")
    let store = UsageStore.isolatedForTesting(
      providers: [
        stepwisePostCredentialDescriptor(strategy: claudeStrategy),
        postCredentialDescriptor(provider: .codex, strategy: codexStrategy),
      ],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [account]
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()

    store.beginRefresh(interaction: .background)
    await codexStrategy.waitUntilRequestStarts()
    let manualRefresh = Task {
      await store.refresh(provider: .claude, interaction: .userInitiated)
    }
    await claudeStrategy.waitUntilRequestStarts(count: 1)
    await codexStrategy.resume()
    for _ in 0 ..< 10 {
      await Task.yield()
    }

    #expect(await claudeStrategy.requestCount == 1)
    #expect(await claudeStrategy.maximumConcurrentRequests == 1)
    await claudeStrategy.resumeNext()
    await manualRefresh.value
    await claudeStrategy.resumeNext()
    await store.inFlightRefresh?.value
  }
}
