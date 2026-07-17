import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeRateLimitTests {
  @Test func timerAndDashboardRefreshMarkAutomaticAndManualInteractions() async {
    let strategy = InteractionSequenceStrategy(outcomes: [.success, .success])
    let store = Self.store(strategy: strategy)

    store.startTimer()
    for _ in 0 ..< 100 {
      let requestCount = await strategy.interactions.count
      if requestCount == 1 {
        break
      }
      await Task.yield()
    }
    await store.inFlightRefresh?.value
    store.timerTask?.cancel()
    await store.refresh()

    let interactions = await strategy.interactions
    #expect(interactions == [.background, .userInitiated])
  }

  @Test func rateLimitFailureKeepsTheLastSuccessfulSnapshot() async throws {
    let strategy = InteractionSequenceStrategy(outcomes: [.success, .rateLimited])
    let store = Self.store(strategy: strategy)

    await store.refresh()
    let successful = try #require(store.snapshots[.claude])

    await store.refresh()

    #expect(store.snapshots[.claude] == successful)
    #expect(store.errors[.claude]?.contains("temporarily rate limited") == true)
  }

  @Test func manualRefreshQueuedBehindTimerKeepsItsBypassPriority() async {
    let strategy = BlockingInteractionStrategy()
    let store = Self.store(strategy: strategy)

    store.beginRefresh(interaction: .background)
    await strategy.waitUntilFirstRequestStarts()
    store.beginRefresh(interaction: .userInitiated)
    store.beginRefresh(interaction: .background)
    await strategy.resumeFirstRequest()
    await store.inFlightRefresh?.value

    #expect(await strategy.interactions == [.background, .userInitiated])
  }

  @Test func explicitAccountScanPropagatesUserInitiatedInteraction() async {
    let strategy = InteractionSequenceStrategy(outcomes: [.success])
    let account = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: .claudeKeychain(service: "rate-limit-test")
    )
    let store = Self.store(strategy: strategy, accounts: [account])
    await store.reloadAccounts()

    await store.refreshAccountUsage(
      for: .claude,
      force: true,
      interaction: .userInitiated
    )

    #expect(await strategy.interactions == [.userInitiated])
  }

  private static func store(
    strategy: any ProviderFetchStrategy,
    accounts: [ProviderAccount] = []
  ) -> UsageStore {
    let metadata = ProviderRegistry.descriptor(for: .claude).metadata
    let descriptor = ProviderDescriptor(
      id: .claude,
      metadata: metadata,
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    return UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: accounts]),
      startsAutomatically: false
    )
  }
}

private actor BlockingInteractionStrategy: ProviderFetchStrategy {
  nonisolated let id = "blocking-interaction"
  nonisolated let kind = ProviderFetchKind.oauth

  private(set) var interactions: [ProviderFetchInteraction] = []
  private var firstRequestStarted = false
  private var firstRequestReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    interactions.append(context.interaction)
    if !firstRequestStarted {
      firstRequestStarted = true
      startWaiters.forEach { $0.resume() }
      startWaiters.removeAll()
      if !firstRequestReleased {
        await withCheckedContinuation { releaseWaiters.append($0) }
      }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Claude"
    )
  }

  func waitUntilFirstRequestStarts() async {
    guard !firstRequestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resumeFirstRequest() {
    firstRequestReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private actor InteractionSequenceStrategy: ProviderFetchStrategy {
  enum Outcome: Sendable {
    case success
    case rateLimited
  }

  nonisolated let id = "interaction-sequence"
  nonisolated let kind = ProviderFetchKind.oauth

  private var outcomes: [Outcome]
  private(set) var interactions: [ProviderFetchInteraction] = []

  init(outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    interactions.append(context.interaction)
    switch outcomes.removeFirst() {
    case .success:
      return ProviderFetchResult(
        usage: UsageSnapshot(
          provider: context.provider,
          plan: "Max 20x",
          primary: RateWindow(kind: .session, usedPercent: 20),
          updatedAt: context.now
        ),
        sourceLabel: "Claude"
      )
    case .rateLimited:
      throw ProviderHTTPError.rateLimited(
        retryAfter: context.now.addingTimeInterval(300)
      )
    }
  }
}
