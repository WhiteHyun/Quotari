import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreProviderActivationTests {
  @Test func fullRefreshSkipsDisabledProviders() async {
    let codexRecorder = AccountRecorder()
    let claudeRecorder = AccountRecorder()
    let store = UsageStore.isolatedForTesting(
      providers: [
        descriptor(for: .codex, strategy: RecordingAccountStrategy(recorder: codexRecorder)),
        descriptor(for: .claude, strategy: RecordingAccountStrategy(recorder: claudeRecorder)),
      ],
      startsAutomatically: false
    )
    store.setProviderEnabled(.codex, enabled: false)

    await store.refresh()

    #expect(await codexRecorder.accounts.isEmpty)
    #expect(await claudeRecorder.accounts == [nil])
    #expect(store.lastRefresh != nil)
  }

  @Test func credentialGuidanceTracksRawDiscoveryResults() async {
    let codexRecorder = AccountRecorder()
    let claudeRecorder = AccountRecorder()
    let codex = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/provider-guidance-auth.json")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [
        descriptor(for: .codex, strategy: RecordingAccountStrategy(recorder: codexRecorder)),
        descriptor(for: .claude, strategy: RecordingAccountStrategy(recorder: claudeRecorder)),
      ],
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [codex]]),
      startsAutomatically: false
    )

    #expect(store.credentialDiscoveryState(for: .codex) == .unknown)
    #expect(store.credentialDiscoveryState(for: .claude) == .unknown)

    await store.reloadAccounts()

    #expect(store.hasDiscoveredCredentials(for: .codex))
    #expect(!store.hasDiscoveredCredentials(for: .claude))
    #expect(store.credentialDiscoveryState(for: .codex) == .present)
    #expect(store.credentialDiscoveryState(for: .claude) == .absent)
  }

  @Test func staleDashboardGenerationCannotStartAfterDisable() async {
    let recorder = AccountRecorder()
    let strategy = RecordingAccountStrategy(recorder: recorder)
    let descriptor = descriptor(for: .codex, strategy: strategy)
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      startsAutomatically: false
    )
    let revision = store.accountRevisions[.codex] ?? 0
    store.setProviderEnabled(.codex, enabled: false)

    _ = await store.serializedProviderFetch(
      descriptor: descriptor,
      now: Date(),
      account: nil,
      capturedRegistryID: nil,
      expectedRevision: revision
    )

    #expect(await recorder.accounts.isEmpty)
  }

  @Test func disablingRejectsAnInFlightProviderResult() async {
    let strategy = GatedNotificationUsageStrategy(snapshot: snapshot(for: .codex))
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(for: .codex, strategy: strategy)],
      startsAutomatically: false
    )
    let refresh = Task { await store.refresh() }
    await strategy.waitUntilFirstRequestStarts()

    store.setProviderEnabled(.codex, enabled: false)
    await strategy.resumeFirstRequest()
    await refresh.value

    #expect(store.snapshots[.codex] == nil)
    #expect(store.sourceLabels[.codex] == nil)
    #expect(store.errors[.codex] == nil)
  }

  @Test func rapidReenableWaitsForAnInFlightFullProviderFetch() async throws {
    let strategy = SerializedActivationStrategy()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(for: .codex, strategy: strategy)],
      startsAutomatically: false
    )
    let originalRefresh = Task { await store.refresh() }
    await strategy.waitUntilFirstRequestStarts()

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    let reactivationRefresh = store.selectionRefreshTasks[.codex]
    try await Task.sleep(for: .milliseconds(20))

    #expect(await strategy.requestCount == 1)
    await strategy.resumeFirstRequest()
    await originalRefresh.value
    await reactivationRefresh?.value

    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
    #expect(store.snapshots[.codex]?.primary?.usedPercent == 20)
  }

  @Test func fullRefreshWaitsForAnInFlightReactivationFetch() async throws {
    let strategy = SerializedActivationStrategy()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(for: .codex, strategy: strategy)],
      startsAutomatically: false
    )
    store.setProviderEnabled(.codex, enabled: false)

    store.setProviderEnabled(.codex, enabled: true)
    let reactivationRefresh = store.selectionRefreshTasks[.codex]
    await strategy.waitUntilFirstRequestStarts()
    let fullRefresh = Task { await store.refresh() }
    try await Task.sleep(for: .milliseconds(20))

    #expect(await strategy.requestCount == 1)
    await strategy.resumeFirstRequest()
    await reactivationRefresh?.value
    await fullRefresh.value

    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }

  @Test func reactivationSerializesWithADashboardFetchRegisteredWhileItWaits() async throws {
    let strategy = SerializedActivationStrategy()
    let descriptor = descriptor(for: .codex, strategy: strategy)
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      startsAutomatically: false
    )
    let drain = ProviderActivityDrainGate()
    let drainingTask = Task { await drain.waitForRelease() }
    store.accountUsageRefreshTasks[.codex] = AccountUsageRefreshTask(
      task: drainingTask,
      force: false
    )
    await drain.waitUntilStarted()

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    let reactivationRefresh = store.selectionRefreshTasks[.codex]
    let dashboardRefresh = Task { await store.refresh() }
    await strategy.waitUntilFirstRequestStarts()
    await drain.release()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await strategy.requestCount == 1)
    await strategy.resumeFirstRequest()
    await dashboardRefresh.value
    await reactivationRefresh?.value

    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }

  @Test func queuedSelectionSerializesWithADashboardFetchRegisteredWhileItWaits() async throws {
    let strategy = SerializedActivationStrategy()
    let descriptor = descriptor(for: .codex, strategy: strategy)
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Selected Codex",
      detail: nil,
      credentialSource: .quotariRegistry(id: "codex:selected")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      startsAutomatically: false
    )
    let drain = ProviderActivityDrainGate()
    let drainingTask = Task { await drain.waitForRelease() }
    store.costTasks[.codex] = CostRefreshTask(
      generation: UUID(),
      credentialTransitionTargetScopeID: nil,
      task: drainingTask
    )
    await drain.waitUntilStarted()

    store.selectAccount(account, for: .codex)
    let selectionRefresh = store.selectionRefreshTasks[.codex]
    let dashboardRefresh = Task { await store.refresh() }
    await drain.release()
    await strategy.waitUntilFirstRequestStarts()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await strategy.requestCount == 1)
    await strategy.resumeFirstRequest()
    await dashboardRefresh.value
    await selectionRefresh?.value

    #expect(await strategy.requestCount == 2)
    #expect(await strategy.maximumConcurrentRequests == 1)
  }

  @Test func reenablingImmediatelyRefreshesOnlyThatProvider() async throws {
    let suiteName = "UsageStoreProviderActivationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let activation = ProviderActivationController(defaults: defaults)
    activation.setProvider(.codex, enabled: false)
    let recorder = AccountRecorder()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(for: .codex, strategy: RecordingAccountStrategy(recorder: recorder))],
      defaults: defaults,
      startsAutomatically: false
    )

    store.setProviderEnabled(.codex, enabled: true)
    await store.selectionRefreshTasks[.codex]?.value

    #expect(await recorder.accounts == [nil])
    #expect(store.snapshots[.codex]?.provider == .codex)
  }

  @Test func disablingClearsTransientStateButPreservesAccountConfiguration() async {
    let account = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Test",
      credentialSource: .quotariRegistry(id: "claude:saved")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(for: .claude, strategy: RecordingAccountStrategy(recorder: AccountRecorder()))],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [account]]),
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.selectAccount(account, for: .claude)
    await store.selectionRefreshTasks[.claude]?.value
    let usage = snapshot(for: .claude)
    store.snapshots[.claude] = usage
    store.sourceLabels[.claude] = "Live"
    store.errors[.claude] = "Old error"
    store.captureErrors[.claude] = "Old capture error"
    store.accountUsage[.claude] = [
      account.id: ProviderAccountUsage(snapshot: usage, sourceLabel: "Live"),
    ]
    store.menuBarPreferences.setUsageSource(.provider(.claude))

    store.setProviderEnabled(.claude, enabled: false)

    #expect(store.accounts[.claude] == [account])
    #expect(store.selectedAccounts[.claude] == account)
    #expect(store.snapshots[.claude] == nil)
    #expect(store.sourceLabels[.claude] == nil)
    #expect(store.errors[.claude] == nil)
    #expect(store.captureErrors[.claude] == nil)
    #expect(store.accountUsage[.claude] == nil)
    #expect(store.menuBarPreferences.usageSource == .mostConstrained)
  }

  private func descriptor(
    for provider: UsageProvider,
    strategy: some ProviderFetchStrategy
  ) -> ProviderDescriptor {
    ProviderDescriptor(
      id: provider,
      metadata: ProviderMetadata(
        displayName: provider.rawValue.capitalized,
        accent: .init(0.2, 0.5, 0.8),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
  }

  private func snapshot(for provider: UsageProvider) -> UsageSnapshot {
    UsageSnapshot(
      provider: provider,
      plan: "Test",
      primary: RateWindow(kind: .session, usedPercent: 25),
      updatedAt: Date()
    )
  }
}

private actor SerializedActivationStrategy: ProviderFetchStrategy {
  let id = "serialized-provider-activation"
  let kind = ProviderFetchKind.api
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequests = 0
  private var concurrentRequests = 0
  private var firstRequestStarted = false
  private var firstRequestStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var firstRequestContinuation: CheckedContinuation<Void, Never>?

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    let ordinal = requestCount
    concurrentRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
    if ordinal == 1 {
      firstRequestStarted = true
      firstRequestStartWaiters.forEach { $0.resume() }
      firstRequestStartWaiters.removeAll()
      await withCheckedContinuation { firstRequestContinuation = $0 }
    }
    concurrentRequests -= 1
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: Double(ordinal * 10)),
        updatedAt: context.now
      ),
      sourceLabel: "Serialized"
    )
  }

  func waitUntilFirstRequestStarts() async {
    guard !firstRequestStarted else { return }
    await withCheckedContinuation { firstRequestStartWaiters.append($0) }
  }

  func resumeFirstRequest() {
    firstRequestContinuation?.resume()
    firstRequestContinuation = nil
  }
}

private actor ProviderActivityDrainGate {
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitForRelease() async {
    started = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func release() {
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
