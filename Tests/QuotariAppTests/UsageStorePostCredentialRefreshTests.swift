import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStorePostCredentialRefreshTests {
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

private func liveClaudeAccount(credentialIdentity: String) -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Claude",
    detail: "Keychain",
    credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    credentialIdentity: credentialIdentity
  )
}

private func postCredentialDescriptor(
  provider: UsageProvider = .claude,
  strategy: GatedPostCredentialUsageStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: provider,
    metadata: ProviderMetadata(
      displayName: provider == .claude ? "Claude" : "Codex",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

private func stepwisePostCredentialDescriptor(
  strategy: StepwisePostCredentialUsageStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

private actor GatedPostCredentialUsageStrategy: ProviderFetchStrategy {
  nonisolated let id = "gated-post-credential"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0
  private var released = false
  private var activeRequests = 0
  private(set) var maximumConcurrentRequests = 0
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    activeRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    defer { activeRequests -= 1 }
    let ready = startWaiters.filter { requestCount >= $0.0 }
    startWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    if !released {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Gated"
    )
  }

  func waitUntilRequestStarts(count: Int = 1) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { startWaiters.append((count, $0)) }
  }

  func resume() {
    released = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private actor StepwisePostCredentialUsageStrategy: ProviderFetchStrategy {
  nonisolated let id = "stepwise-post-credential"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0
  private var activeRequests = 0
  private(set) var maximumConcurrentRequests = 0
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releasePermits = 0

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    activeRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    defer { activeRequests -= 1 }
    let ready = startWaiters.filter { requestCount >= $0.0 }
    startWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    if releasePermits > 0 {
      releasePermits -= 1
    } else {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stepwise"
    )
  }

  func waitUntilRequestStarts(count: Int) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { startWaiters.append((count, $0)) }
  }

  func resumeNext() {
    guard !releaseWaiters.isEmpty else {
      releasePermits += 1
      return
    }
    releaseWaiters.removeFirst().resume()
  }
}

actor PostCredentialRefreshGate {
  private(set) var requestedDurations: [Duration] = []
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func sleep(for duration: Duration) async throws {
    requestedDurations.append(duration)
    let ready = requestWaiters.filter { requestedDurations.count >= $0.0 }
    requestWaiters.removeAll { requestedDurations.count >= $0.0 }
    ready.forEach { $0.1.resume() }
    await withCheckedContinuation { continuations.append($0) }
  }

  func waitUntilRequested(count: Int = 1) async {
    guard requestedDurations.count < count else { return }
    await withCheckedContinuation { requestWaiters.append((count, $0)) }
  }

  func resumeAll() {
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }
}
