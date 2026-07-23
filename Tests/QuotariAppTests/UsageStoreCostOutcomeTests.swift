import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreCostOutcomeTests {
  @Test func unavailableRefreshPreservesPreviousValidChart() async throws {
    let localCost = Self.localCost
    let day = Self.day
    let estimator = OutcomeCostEstimator(outcomes: [.updated(localCost), .unavailable])
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor],
      costEstimator: estimator,
      currentDate: { day },
      startsAutomatically: false
    )

    await store.refresh()
    try await Self.waitForCost(localCost, in: store)
    await store.refresh()
    try await Self.waitForOutcomeCalls(2, estimator: estimator)

    #expect(store.snapshots[.codex]?.cost == localCost)
  }

  @Test func confirmedEmptyRefreshClearsPreviousValidChart() async throws {
    let localCost = Self.localCost
    let day = Self.day
    let estimator = OutcomeCostEstimator(outcomes: [.updated(localCost), .confirmedEmpty])
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor],
      costEstimator: estimator,
      currentDate: { day },
      startsAutomatically: false
    )

    await store.refresh()
    try await Self.waitForCost(localCost, in: store)
    await store.refresh()
    try await Self.waitForCostCleared(in: store)

    #expect(store.snapshots[.codex]?.cost == nil)
  }

  @Test func nextDayUnavailableRefreshDoesNotCarryYesterdaysCost() async throws {
    let localCost = Self.localCost
    let estimator = OutcomeCostEstimator(outcomes: [.updated(localCost), .unavailable])
    let dates = [Self.day, Self.day.addingTimeInterval(86400)]
    let clock = TestDateSource(now: dates[0])
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(strategy: DatedOutcomeUsageStrategy(dates: dates))],
      costEstimator: estimator,
      currentDate: { clock.now },
      startsAutomatically: false
    )

    await store.refresh()
    try await Self.waitForCost(localCost, in: store)
    clock.now = dates[1]
    await store.refresh()
    try await Self.waitForCostCleared(in: store)

    #expect(store.snapshots[.codex]?.cost == nil)
  }

  @Test func updatedRefreshCrossingMidnightCannotInstallYesterdaysCost() async throws {
    let estimator = SuspendedOutcomeCostEstimator(outcome: .updated(Self.localCost))
    let clock = TestDateSource(now: Self.day)
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor],
      costEstimator: estimator,
      currentDate: { clock.now },
      startsAutomatically: false
    )

    await store.refresh()
    await estimator.waitUntilStarted()
    clock.now = Self.day.addingTimeInterval(86400)
    await estimator.finish()
    try await Self.waitForOutcomeCompletions(1, estimator: estimator)

    #expect(store.snapshots[.codex]?.cost == nil)
  }

  private static let day = Date(timeIntervalSince1970: 1_783_478_400)

  private static let localCost = CostSummary(
    todaySpend: 1.25,
    monthSpend: 2.50,
    monthTokens: 1000,
    latestTokens: 200,
    topModel: "gpt-5",
    sourceDescription: "Estimated from local logs",
    daily: [
      DailyCost(date: day.addingTimeInterval(-86400), spend: 0.50, tokens: 500),
      DailyCost(date: day, spend: 1.00, tokens: 500),
    ]
  )

  private static var descriptor: ProviderDescriptor {
    descriptor(strategy: OutcomeUsageStrategy(date: day))
  }

  private static func descriptor(
    strategy: some ProviderFetchStrategy
  ) -> ProviderDescriptor {
    ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
  }

  private static func waitForCost(_ cost: CostSummary, in store: UsageStore) async throws {
    for _ in 0 ..< 100 {
      if store.snapshots[.codex]?.cost == cost {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(store.snapshots[.codex]?.cost == cost)
  }

  private static func waitForCostCleared(in store: UsageStore) async throws {
    for _ in 0 ..< 100 {
      if store.snapshots[.codex]?.cost == nil {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(store.snapshots[.codex]?.cost == nil)
  }

  private static func waitForOutcomeCalls(
    _ expected: Int,
    estimator: OutcomeCostEstimator
  ) async throws {
    for _ in 0 ..< 100 {
      if await estimator.callCount >= expected {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await estimator.callCount >= expected)
  }

  private static func waitForOutcomeCompletions(
    _ expected: Int,
    estimator: SuspendedOutcomeCostEstimator
  ) async throws {
    for _ in 0 ..< 100 {
      if await estimator.completionCount >= expected {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await estimator.completionCount >= expected)
  }
}

private final class TestDateSource: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  var now: Date {
    get {
      lock.withLock { value }
    }
    set {
      lock.withLock { value = newValue }
    }
  }

  init(now: Date) {
    value = now
  }
}

private actor SuspendedOutcomeCostEstimator: UsageCostEstimating {
  private let outcome: UsageCostRefreshOutcome
  private var continuation: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var completionCount = 0

  init(outcome: UsageCostRefreshOutcome) {
    self.outcome = outcome
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }

  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      startWaiters.forEach { $0.resume() }
      startWaiters.removeAll()
    }
    completionCount += 1
    return outcome
  }

  func waitUntilStarted() async {
    guard continuation == nil else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

private actor OutcomeCostEstimator: UsageCostEstimating {
  private var outcomes: [UsageCostRefreshOutcome]
  private(set) var callCount = 0

  init(outcomes: [UsageCostRefreshOutcome]) {
    self.outcomes = outcomes
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }

  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome {
    callCount += 1
    guard !outcomes.isEmpty else { return .unavailable }
    return outcomes.removeFirst()
  }
}

private struct OutcomeUsageStrategy: ProviderFetchStrategy {
  let id = "outcome-usage"
  let kind = ProviderFetchKind.api
  let date: Date

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        cost: CostSummary(
          todaySpend: 0,
          monthSpend: 0,
          monthTokens: 0,
          latestTokens: 0,
          sourceDescription: "Reported by provider",
          daily: [DailyCost(date: date, spend: 0, tokens: 0)]
        ),
        updatedAt: date
      ),
      sourceLabel: "Stub"
    )
  }
}

private actor DatedOutcomeUsageStrategy: ProviderFetchStrategy {
  nonisolated let id = "dated-outcome-usage"
  nonisolated let kind = ProviderFetchKind.api
  private var dates: [Date]

  init(dates: [Date]) {
    self.dates = dates
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let date = dates.count > 1 ? dates.removeFirst() : dates[0]
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        cost: CostSummary(
          todaySpend: 0,
          monthSpend: 0,
          monthTokens: 0,
          latestTokens: 0,
          sourceDescription: "Reported by provider",
          daily: [DailyCost(date: date, spend: 0, tokens: 0)]
        ),
        updatedAt: date
      ),
      sourceLabel: "Stub"
    )
  }
}
