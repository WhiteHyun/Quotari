import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreProviderActivationTaskTests {
  @Test func disabledProviderKeepsAccountsButHidesAndSkipsAccountUsage() async throws {
    let account = Self.codexAccount
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    defer { try? FileManager.default.removeItem(at: selectionStore.url) }
    try selectionStore.save([.codex: account])
    let gate = ProviderActivationFetchGate()
    await gate.release()
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(provider: .codex, strategy: GatedUsageStrategy(gate: gate))],
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [account]]),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.reloadAccounts()
    store.setProviderEnabled(.codex, enabled: false)
    store.accountUsage[.codex] = [
      account.id: ProviderAccountUsage(snapshot: Self.snapshot(provider: .codex, usedPercent: 55)),
    ]

    #expect(store.accounts[.codex] == [account])
    #expect(store.selectedAccounts[.codex] == account)
    #expect(store.activeAccount(for: .codex) == nil)
    #expect(store.accountUsage(for: account) == nil)

    await store.refreshAccountUsage(for: .codex, force: true)
    #expect(await gate.accountRequestCount == 0)
  }

  @Test func rapidReenableReplacesTheCancelledAccountUsageGeneration() async {
    let account = Self.codexAccount
    let gate = ProviderActivationFetchGate()
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(provider: .codex, strategy: GatedUsageStrategy(gate: gate))],
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [account]]),
      startsAutomatically: false
    )
    await store.reloadAccounts()

    let originalRefresh = Task {
      await store.refreshAccountUsage(for: .codex, force: true)
    }
    let didStart = await Self.waitUntilAccountRequestStarts(gate)
    #expect(didStart)
    guard didStart else {
      originalRefresh.cancel()
      return
    }

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    let replacementRefresh = Task {
      await store.refreshAccountUsage(for: .codex)
    }
    await gate.release()

    await originalRefresh.value
    await replacementRefresh.value

    #expect(await gate.accountRequestCount == 2)
    #expect(
      store.accountUsage[.codex]?[account.id]?.snapshot?.primary?.usedPercent == 20
    )
  }

  @Test func disabledClaudeDiscardsInFlightProfileAndStartsNoMoreWork() async throws {
    let account = Self.claudeAccount
    let gate = ProviderActivationFetchGate()
    let fetcher = GatedClaudeProfileFetcher(gate: gate)
    let profileStore = ClaudeProfileStore.temporaryForTesting()
    defer { try? FileManager.default.removeItem(at: profileStore.url) }
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(provider: .claude, strategy: NeverAvailableStrategy())],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      profileFetcher: fetcher,
      profileStore: profileStore,
      claudeCredentialLoader: { _ in
        ClaudeCredentials(accessToken: "claude-access", refreshToken: "claude-refresh")
      },
      startsAutomatically: false
    )

    await store.reloadAccounts()
    await gate.waitUntilProfileRequestStarts()
    store.setProviderEnabled(.claude, enabled: false)
    await gate.release()
    try await Self.waitUntil { store.profileFetchTasks.isEmpty }

    #expect(store.accounts[.claude] == [account])
    #expect(store.claudeProfiles[account.id] == nil)
    #expect(profileStore.load().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: profileStore.url.path))

    await store.reloadAccounts()
    try await Task.sleep(for: .milliseconds(30))
    #expect(await gate.profileRequestCount == 1)
  }

  @Test func rapidReenableDrainsTheCancelledCostScanBeforeStartingAnother() async throws {
    let estimator = GatedProviderActivationCostEstimator()
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(
        provider: .codex,
        strategy: GatedUsageStrategy(gate: ProviderActivationFetchGate(released: true))
      )],
      costEstimator: estimator,
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [Self.codexAccount]]),
      startsAutomatically: false
    )

    await store.reloadAccounts()
    await store.refresh()
    await estimator.waitUntilRequestCount(1)

    store.setProviderEnabled(.codex, enabled: false)
    store.selectAccount(Self.codexAccount, for: .codex)
    store.setProviderEnabled(.codex, enabled: true)
    let reactivationRefresh = store.selectionRefreshTasks[.codex]
    try await Task.sleep(for: .milliseconds(20))

    #expect(await estimator.requestCount == 1)
    await estimator.releaseNext()
    await reactivationRefresh?.value
    await estimator.waitUntilRequestCount(2)

    #expect(await estimator.maximumConcurrentRequests == 1)
    await estimator.releaseNext()
    await store.costTasks[.codex]?.task.value
  }

  private static let codexAccount = ProviderAccount(
    provider: .codex,
    displayName: "Codex Test",
    detail: "Test",
    credentialSource: .codexAuthFile(path: "/tmp/quotari-provider-activation/auth.json"),
    credentialIdentity: "codex-test"
  )

  private static let claudeAccount = ProviderAccount(
    provider: .claude,
    displayName: "Claude Test",
    detail: "Test",
    credentialSource: .claudeKeychain(service: "Quotari Provider Activation Tests"),
    credentialIdentity: "claude-test"
  )

  private static func descriptor(
    provider: UsageProvider,
    strategy: some ProviderFetchStrategy
  ) -> ProviderDescriptor {
    ProviderDescriptor(
      id: provider,
      metadata: ProviderMetadata(
        displayName: provider.rawValue.capitalized,
        accent: .init(0.2, 0.4, 0.6),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
  }

  private static func snapshot(provider: UsageProvider, usedPercent: Double) -> UsageSnapshot {
    UsageSnapshot(
      provider: provider,
      plan: "Test",
      primary: RateWindow(kind: .session, usedPercent: usedPercent),
      updatedAt: Date()
    )
  }

  private static func waitUntil(
    attempts: Int = 100,
    _ condition: @MainActor () -> Bool
  ) async throws {
    for _ in 0 ..< attempts {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw ProviderActivationTaskTestError.timedOut
  }

  private static func waitUntilAccountRequestStarts(_ gate: ProviderActivationFetchGate) async -> Bool {
    for _ in 0 ..< 100 {
      if await gate.accountRequestCount > 0 {
        return true
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }
}

private actor ProviderActivationFetchGate {
  private(set) var accountRequestCount = 0
  private(set) var profileRequestCount = 0
  private var accountRequestStarted = false
  private var profileRequestStarted = false
  private var isReleased: Bool
  private var accountStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var profileStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(released: Bool = false) {
    isReleased = released
  }

  func beginUsageRequest(account: ProviderAccount?) async -> Int {
    let ordinal: Int
    if account == nil {
      ordinal = 0
    } else {
      accountRequestCount += 1
      ordinal = accountRequestCount
      accountRequestStarted = true
      accountStartWaiters.forEach { $0.resume() }
      accountStartWaiters.removeAll()
    }
    await waitForRelease()
    return ordinal
  }

  func beginProfileRequest() async {
    profileRequestCount += 1
    profileRequestStarted = true
    profileStartWaiters.forEach { $0.resume() }
    profileStartWaiters.removeAll()
    await waitForRelease()
  }

  func waitUntilAccountRequestStarts() async {
    guard !accountRequestStarted else { return }
    await withCheckedContinuation { accountStartWaiters.append($0) }
  }

  func waitUntilProfileRequestStarts() async {
    guard !profileRequestStarted else { return }
    await withCheckedContinuation { profileStartWaiters.append($0) }
  }

  func release() {
    isReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }

  private func waitForRelease() async {
    guard !isReleased else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }
}

private actor GatedProviderActivationCostEstimator: UsageCostEstimating {
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequests = 0
  private var concurrentRequests = 0
  private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    requestCount += 1
    concurrentRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
    let ready = requestCountWaiters.filter { requestCount >= $0.0 }
    requestCountWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    await withCheckedContinuation { releaseWaiters.append($0) }
    concurrentRequests -= 1
    return nil
  }

  func waitUntilRequestCount(_ count: Int) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { requestCountWaiters.append((count, $0)) }
  }

  func releaseNext() {
    guard !releaseWaiters.isEmpty else { return }
    releaseWaiters.removeFirst().resume()
  }
}

private struct GatedUsageStrategy: ProviderFetchStrategy {
  let gate: ProviderActivationFetchGate
  let id = "provider-activation-gated-usage"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let ordinal = await gate.beginUsageRequest(account: context.account)
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        account: context.account?.displayName,
        primary: RateWindow(kind: .session, usedPercent: Double(ordinal * 10)),
        updatedAt: context.now
      ),
      sourceLabel: "Activation Test"
    )
  }
}

private struct NeverAvailableStrategy: ProviderFetchStrategy {
  let id = "provider-activation-never-available"
  let kind = ProviderFetchKind.api

  func isAvailable(_ context: ProviderFetchContext) async -> Bool {
    false
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    throw ProviderFetchError.noStrategyAvailable(context.provider)
  }
}

private struct GatedClaudeProfileFetcher: ClaudeProfileFetching {
  let gate: ProviderActivationFetchGate

  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    await gate.beginProfileRequest()
    return ClaudeProfile(email: "stale@example.com")
  }
}

private enum ProviderActivationTaskTestError: Error {
  case timedOut
}
