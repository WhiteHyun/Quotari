import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStorePostCredentialRefreshTests {
  @Test func immediateCodexRefreshRecordsCancellation() async {
    let strategy = GatedPostCredentialUsageStrategy()
    let recorder = AppCredentialLifecycleEventRecorder()
    let scheduledAccount = ProviderAccount(
      provider: .codex,
      displayName: "Scheduled",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:scheduled")
    )
    let replacementAccount = ProviderAccount(
      provider: .codex,
      displayName: "Replacement",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:replacement")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(provider: .codex, strategy: strategy)],
      credentialLifecycleLogger: recorder.logger,
      startsAutomatically: false
    )
    store.reconciledSelectionOrigins[.codex] = scheduledAccount

    store.enqueuePostCredentialRefresh(for: .codex)
    await strategy.waitUntilRequestStarts()
    store.reconciledSelectionOrigins[.codex] = replacementAccount
    store.selectionRefreshTasks[.codex]?.cancel()
    await strategy.resume()
    await store.selectionRefreshTasks[.codex]?.value
    for _ in 0 ..< 10 where !recorder.events.contains(where: {
      $0.kind == .postSwitchRefreshCancelled
    }) {
      await Task.yield()
    }

    #expect(recorder.events.map(\.kind) == [
      .postSwitchRefreshScheduled,
      .postSwitchRefreshStarted,
      .postSwitchRefreshCancelled,
    ])
    #expect(recorder.events.allSatisfy { $0.accountID == "opaque:\(scheduledAccount.id)" })
  }

  @Test func newerClaudeCredentialChangeSupersedesThePendingRefresh() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let store = makeStore(strategy: strategy, delay: delay)

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested(count: 1)
    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested(count: 2)

    #expect(await strategy.requestCount == 0)
    await delay.resumeAll()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await store.selectionRefreshTasks[.claude]?.value

    #expect(await strategy.requestCount == 1)
  }

  @Test func manualRefreshBypassesAndCancelsTheClaudeDelay() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let store = makeStore(strategy: strategy, delay: delay)

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await store.refresh(provider: .claude)

    #expect(await strategy.requestCount == 1)
    #expect(store.delayedCredentialRefreshTasks[.claude] == nil)

    await delay.resumeAll()
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 1)
  }

  @Test func disablingClaudeCancelsThePendingRefresh() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let store = makeStore(strategy: strategy, delay: delay)

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    store.setProviderEnabled(.claude, enabled: false)

    #expect(store.delayedCredentialRefreshTasks[.claude] == nil)
    await delay.resumeAll()
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 0)
  }

  @Test func timerRefreshDoesNotBypassTheClaudeDelay() async {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let store = makeStore(strategy: strategy, delay: delay)

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    store.beginRefresh(interaction: .background)
    await store.inFlightRefresh?.value

    #expect(await strategy.requestCount == 0)
    await delay.resumeAll()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await store.selectionRefreshTasks[.claude]?.value
    #expect(await strategy.requestCount == 1)
  }

  private func makeStore(
    strategy: AutomaticCaptureCountingStrategy,
    delay: PostCredentialRefreshGate
  ) -> UsageStore {
    UsageStore.isolatedForTesting(
      providers: [countingClaudeDescriptor(strategy: strategy)],
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
  }
}

@MainActor
struct PostCredentialRefreshCoordinationTests {
  @Test func timerRefreshDoesNotDuplicateTheFetchWhileTheDelayedRequestRuns() async {
    let strategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(strategy: strategy)],
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts()

    store.beginRefresh(interaction: .background)
    await store.inFlightRefresh?.value
    #expect(await strategy.requestCount == 1)

    await strategy.resume()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await store.selectionRefreshTasks[.claude]?.value
    #expect(await strategy.requestCount == 1)
  }

  @Test func automaticRediscoveryDoesNotCancelTheClaudeDelay() async throws {
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let current = liveClaudeAccount(credentialIdentity: "current")
    let rotated = liveClaudeAccount(credentialIdentity: "rotated")
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.claude: [current]]
    ))
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.claude: current])
    let store = UsageStore.isolatedForTesting(
      providers: [countingClaudeDescriptor(strategy: strategy)],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    let requestsBeforeDelay = await strategy.requestCount

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    discovery.update(StaticAccountDiscovery(accounts: [.claude: [rotated]]))
    await store.reloadAccounts()
    await store.selectionRefreshTasks[.claude]?.value

    #expect(store.delayedCredentialRefreshTasks[.claude] != nil)
    #expect(await strategy.requestCount == requestsBeforeDelay)

    await delay.resumeAll()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await store.selectionRefreshTasks[.claude]?.value
    #expect(await strategy.requestCount == requestsBeforeDelay + 1)
  }

  @Test func automaticRediscoveryQueuesReplacementWhileDelayedFetchRuns() async throws {
    let strategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let current = liveClaudeAccount(credentialIdentity: "current")
    let rotated = liveClaudeAccount(credentialIdentity: "rotated")
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.claude: [current]]
    ))
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.claude: current])
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(strategy: strategy)],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts(count: 1)

    discovery.update(StaticAccountDiscovery(accounts: [.claude: [rotated]]))
    await store.reloadAccounts()
    #expect(await strategy.requestCount == 1)

    await strategy.resume()
    await strategy.waitUntilRequestStarts(count: 2)
    await store.selectionRefreshTasks[.claude]?.value
    #expect(store.selectedAccounts[.claude] == rotated)
    #expect(await strategy.requestCount == 2)
  }

  @Test func delayedGateCoversAutomaticReplacementThroughMonitoredRefresh() async throws {
    let claudeStrategy = StepwisePostCredentialUsageStrategy()
    let codexStrategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let current = liveClaudeAccount(credentialIdentity: "current")
    let rotated = liveClaudeAccount(credentialIdentity: "rotated")
    let monitored = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:monitored")
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.claude: [current, monitored]]
    ))
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.claude: current])
    let store = UsageStore.isolatedForTesting(
      providers: [
        stepwisePostCredentialDescriptor(strategy: claudeStrategy),
        postCredentialDescriptor(provider: .codex, strategy: codexStrategy),
      ],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.monitoredAccounts[.claude] = [monitored]

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await claudeStrategy.waitUntilRequestStarts(count: 1)
    discovery.update(StaticAccountDiscovery(
      accounts: [.claude: [rotated, monitored]]
    ))
    await store.reloadAccounts()

    store.beginRefresh(interaction: .background)
    await codexStrategy.waitUntilRequestStarts()
    await claudeStrategy.resumeNext()
    await claudeStrategy.waitUntilRequestStarts(count: 2)
    #expect(store.delayedCredentialRefreshTasks[.claude] != nil)

    await codexStrategy.resume()
    await store.inFlightRefresh?.value
    #expect(await claudeStrategy.requestCount == 2)
    #expect(await claudeStrategy.maximumConcurrentRequests == 1)

    await claudeStrategy.resumeNext()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    #expect(store.delayedCredentialRefreshTasks[.claude] == nil)
  }

  @Test func manualAccountRefreshDrainsTheRunningDelayedFetch() async {
    let strategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let account = liveClaudeAccount(credentialIdentity: "current")
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(strategy: strategy)],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts(count: 1)

    let manualRefresh = Task {
      await store.refreshAccountUsage(
        for: .claude,
        force: true,
        interaction: .userInitiated
      )
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 1)
    #expect(await strategy.maximumConcurrentRequests == 1)

    await strategy.resume()
    await manualRefresh.value
    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }

  @Test func manualAccountRefreshCancelsQueuedAutomaticReplacement() async throws {
    let strategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let current = liveClaudeAccount(credentialIdentity: "current")
    let rotated = liveClaudeAccount(credentialIdentity: "rotated")
    let latest = liveClaudeAccount(credentialIdentity: "latest")
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.claude: [current]]
    ))
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.claude: current])
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(strategy: strategy)],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      postCredentialRefreshSleep: delay.sleep,
      startsAutomatically: false
    )
    await store.reloadAccounts()

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts(count: 1)
    discovery.update(StaticAccountDiscovery(accounts: [.claude: [rotated]]))
    await store.reloadAccounts()
    discovery.update(StaticAccountDiscovery(accounts: [.claude: [latest]]))
    await store.reloadAccounts()

    let manualRefresh = Task {
      await store.refreshAccountUsage(
        for: .claude,
        force: true,
        interaction: .userInitiated
      )
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    #expect(await strategy.requestCount == 1)

    await strategy.resume()
    await manualRefresh.value
    await store.selectionRefreshTasks[.claude]?.value
    #expect(store.selectedAccounts[.claude] == latest)
    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }
}
