import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreInsightsMonitoringTests {
  @Test func logEventInvalidatesAndRefreshesOnlyTheAffectedProvider() async throws {
    let monitor = RecordingUsageInsightsChangeMonitor()
    let estimator = RecordingObservedUsageEstimator()
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    let codex = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/codex/auth.json"),
      credentialIdentity: "codex-account"
    )
    let claude = ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: nil,
      credentialSource: .claudeCredentialsFile(path: "/tmp/claude/.credentials.json"),
      credentialIdentity: "claude-account"
    )
    try selectionStore.save([.codex: codex, .claude: claude])
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: estimator,
      usageInsightsChangeMonitor: monitor,
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )
    store.snapshots[.codex] = UsageSnapshot(
      provider: .codex,
      plan: "Test",
      primary: RateWindow(kind: .session, usedPercent: 10),
      cost: Self.localCost(tokens: 100),
      updatedAt: Self.referenceDay
    )

    store.reconfigureUsageInsightsMonitoring()
    let observations = monitor.observations
    #expect(Set(observations.map(\.key)) == [
      UsageInsightsObservationKey(provider: .codex, credentialScopeID: codex.credentialScopeID),
      UsageInsightsObservationKey(provider: .claude, credentialScopeID: claude.credentialScopeID),
    ])

    monitor.trigger(provider: .codex)
    try await eventually {
      estimator.refreshedProviders == [.codex]
        && store.usageInsightsState(for: .codex) == .empty(.noLocalUsage)
    }

    #expect(estimator.invalidatedProviders == [.codex])
    #expect(store.usageInsightsState(for: .codex) == .empty(.noLocalUsage))
    #expect(store.usageInsightsState(for: .claude) == .idle)
  }

  @Test func disablingProviderRemovesItsObservation() {
    let monitor = RecordingUsageInsightsChangeMonitor()
    let estimator = RecordingObservedUsageEstimator()
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: estimator,
      usageInsightsChangeMonitor: monitor,
      startsAutomatically: false
    )

    store.reconfigureUsageInsightsMonitoring()
    #expect(Set(monitor.observations.map(\.key.provider)) == Set(UsageProvider.allCases))

    store.setProviderEnabled(.claude, enabled: false)

    #expect(monitor.observations.map(\.key.provider) == [.codex])
  }

  @Test func localLogRefreshDoesNotOverrideDetailedProviderCost() {
    let estimator = RecordingObservedUsageEstimator()
    let reportedCost = Self.localCost(
      tokens: 100,
      sourceDescription: "Reported by provider"
    )
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: estimator,
      startsAutomatically: false
    )
    store.snapshots[.codex] = UsageSnapshot(
      provider: .codex,
      plan: "Test",
      primary: RateWindow(kind: .session, usedPercent: 10),
      cost: reportedCost,
      updatedAt: Self.referenceDay
    )

    store.refreshUsageInsightsAfterLocalLogChange(provider: .codex)

    #expect(estimator.invalidatedProviders.isEmpty)
    #expect(estimator.refreshedProviders.isEmpty)
    #expect(store.snapshots[.codex]?.cost == reportedCost)
  }

  @Test func localLogRefreshCarriesLatestCredentialTransition() async throws {
    let estimator = RecordingObservedUsageEstimator()
    let transition = UsageCostCredentialTransition(
      targetScopeID: "claude:rotated",
      sourceScopeIDs: ["claude:previous"]
    )
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: estimator,
      startsAutomatically: false
    )
    store.latestUsageCostCredentialTransitions[.claude] = transition

    store.refreshUsageInsightsAfterLocalLogChange(provider: .claude)
    try await eventually {
      estimator.credentialTransitions == [transition]
    }

    #expect(estimator.invalidatedProviders == [.claude])
  }

  @Test func newerLogEventReplacesAnInFlightScanWithoutPublishingItsResult() async throws {
    let firstCost = Self.localCost(tokens: 100)
    let secondCost = Self.localCost(tokens: 200)
    let estimator = GatedObservedUsageEstimator(outcomes: [
      .updated(firstCost),
      .updated(secondCost),
    ])
    let monitor = RecordingUsageInsightsChangeMonitor()
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      costEstimator: estimator,
      usageInsightsChangeMonitor: monitor,
      startsAutomatically: false
    )
    store.snapshots[.codex] = UsageSnapshot(
      provider: .codex,
      plan: "Test",
      primary: RateWindow(kind: .session, usedPercent: 10),
      updatedAt: Self.referenceDay
    )
    store.reconfigureUsageInsightsMonitoring()

    monitor.trigger(provider: .codex)
    await estimator.waitUntilRequestCount(1)
    monitor.trigger(provider: .codex)
    try await Task.sleep(for: .milliseconds(20))

    #expect(await estimator.requestCount == 1)
    await estimator.releaseNext()
    await estimator.waitUntilRequestCount(2)
    #expect(await estimator.maximumConcurrentRequests == 1)
    #expect(store.snapshots[.codex]?.cost == nil)

    let replacementTask = store.costTasks[.codex]?.task
    await estimator.releaseNext()
    await replacementTask?.value

    #expect(store.snapshots[.codex]?.cost == secondCost)
  }

  private func eventually(
    _ condition: @escaping @MainActor @Sendable () -> Bool
  ) async throws {
    for _ in 0 ..< 100 {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
  }

  private static let referenceDay = Date(timeIntervalSince1970: 1_783_478_400)

  private static func localCost(
    tokens: Int,
    sourceDescription: String = "Estimated from local logs"
  ) -> CostSummary {
    CostSummary(
      todaySpend: Double(tokens),
      monthSpend: Double(tokens),
      monthTokens: tokens,
      latestTokens: tokens,
      sourceDescription: sourceDescription,
      daily: [
        DailyCost(date: referenceDay.addingTimeInterval(-86400), spend: Double(tokens), tokens: tokens),
        DailyCost(date: referenceDay, spend: Double(tokens), tokens: tokens),
      ]
    )
  }
}

private final class RecordingUsageInsightsChangeMonitor: UsageInsightsChangeMonitoring, @unchecked Sendable {
  private let lock = NSLock()
  private var storedObservations: [UsageInsightsLogObservation] = []
  private var callback: (@Sendable (Set<UsageInsightsObservationKey>) -> Void)?

  var observations: [UsageInsightsLogObservation] {
    lock.withLock { storedObservations }
  }

  func replaceObservations(
    _ observations: [UsageInsightsLogObservation],
    onChange: @escaping @Sendable (Set<UsageInsightsObservationKey>) -> Void
  ) {
    lock.withLock {
      storedObservations = observations
      callback = onChange
    }
  }

  func stop() {
    lock.withLock {
      storedObservations = []
      callback = nil
    }
  }

  func trigger(provider: UsageProvider) {
    let value = lock.withLock {
      (
        storedObservations.first(where: { $0.key.provider == provider })?.key,
        callback
      )
    }
    guard let key = value.0, let callback = value.1 else { return }
    callback([key])
  }
}

private final class RecordingObservedUsageEstimator: UsageCostEstimating, @unchecked Sendable {
  private let lock = NSLock()
  private var invalidated: [UsageProvider] = []
  private var refreshed: [UsageProvider] = []
  private var transitions: [UsageCostCredentialTransition?] = []

  var invalidatedProviders: [UsageProvider] {
    lock.withLock { invalidated }
  }

  var refreshedProviders: [UsageProvider] {
    lock.withLock { refreshed }
  }

  var credentialTransitions: [UsageCostCredentialTransition?] {
    lock.withLock { transitions }
  }

  func usageInsightsObservationRoots(
    provider: UsageProvider,
    account: ProviderAccount?
  ) -> [URL] {
    [
      URL(fileURLWithPath: "/tmp/\(provider.rawValue)/\(account?.credentialScopeID ?? "automatic")")
        .appendingPathComponent("sessions", isDirectory: true),
    ]
  }

  func costSummary(
    provider _: UsageProvider,
    now _: Date,
    historyDays _: Int
  ) async -> CostSummary? {
    nil
  }

  func costRefreshOutcome(
    provider: UsageProvider,
    account _: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now _: Date,
    historyDays _: Int
  ) async -> UsageCostRefreshOutcome {
    lock.withLock {
      refreshed.append(provider)
      transitions.append(credentialTransition)
    }
    return .confirmedEmpty
  }

  func invalidateInsights(
    provider: UsageProvider,
    account _: ProviderAccount?,
    historyDays _: Int
  ) {
    lock.withLock {
      invalidated.append(provider)
    }
  }
}

private actor GatedObservedUsageEstimator: UsageCostEstimating {
  private let outcomes: [UsageCostRefreshOutcome]
  private var concurrentRequests = 0
  private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequests = 0

  init(outcomes: [UsageCostRefreshOutcome]) {
    self.outcomes = outcomes
  }

  nonisolated func usageInsightsObservationRoots(
    provider: UsageProvider,
    account _: ProviderAccount?
  ) -> [URL] {
    [URL(fileURLWithPath: "/tmp/\(provider.rawValue)/sessions", isDirectory: true)]
  }

  func costSummary(
    provider _: UsageProvider,
    now _: Date,
    historyDays _: Int
  ) async -> CostSummary? {
    nil
  }

  func costRefreshOutcome(
    provider _: UsageProvider,
    account _: ProviderAccount?,
    now _: Date,
    historyDays _: Int
  ) async -> UsageCostRefreshOutcome {
    let index = requestCount
    requestCount += 1
    concurrentRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
    let ready = requestCountWaiters.filter { requestCount >= $0.0 }
    requestCountWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    await withCheckedContinuation { releaseWaiters.append($0) }
    concurrentRequests -= 1
    return outcomes[index]
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
