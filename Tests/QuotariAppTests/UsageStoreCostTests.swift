import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreCostTests {
  @Test func localCostReplacesSparseReportedCost() async throws {
    let localCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: StubCostEstimator(cost: localCost)
    )

    let snapshot = try await Self.waitForCost(in: store, matching: localCost)

    #expect(snapshot.cost == localCost)
  }

  @Test func providerCostWithUsageSeriesIsPreserved() async throws {
    let providerCost = Self.costSummary(
      todaySpend: 3.70,
      monthSpend: 5.20,
      monthTokens: 2000,
      latestTokens: 500,
      sourceDescription: "Reported by provider",
      daily: Self.dailySeries(tokens: 2000)
    )
    let localCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(cost: providerCost)],
      costEstimator: StubCostEstimator(cost: localCost)
    )

    let snapshot = try await Self.waitForSnapshot(in: store)

    #expect(snapshot.cost == providerCost)
  }

  @Test func quotaSnapshotDoesNotWaitForLocalCostScan() async throws {
    let localCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: DelayedCostEstimator(cost: localCost, delay: .milliseconds(250))
    )

    let initial = try await Self.waitForSnapshot(in: store, attempts: 10)
    #expect(initial.primary?.usedPercent == 10)
    #expect(initial.cost == nil)

    let updated = try await Self.waitForCost(in: store, matching: localCost)
    #expect(updated.cost == localCost)
  }

  @Test func cachedLocalCostIsDisplayedBeforeFreshScanFinishes() async throws {
    let cachedCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let freshCost = Self.costSummary(
      todaySpend: 2.00,
      monthSpend: 4.00,
      monthTokens: 2000,
      latestTokens: 400,
      daily: Self.dailySeries(tokens: 2000)
    )
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: CachedThenDelayedCostEstimator(
        cachedCost: cachedCost,
        freshCost: freshCost,
        delay: .milliseconds(250)
      )
    )

    let initial = try await Self.waitForSnapshot(in: store, attempts: 10)
    #expect(initial.cost == cachedCost)

    let updated = try await Self.waitForCost(in: store, matching: freshCost)
    #expect(updated.cost == freshCost)
  }

  @Test func sparseReportedCostDoesNotReplaceExistingLocalChart() async throws {
    let localCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: StubCostEstimator(cost: localCost)
    )

    _ = try await Self.waitForCost(in: store, matching: localCost)
    await store.refresh()

    let snapshot = try #require(store.snapshots[.codex])
    #expect(snapshot.cost == localCost)
  }

  @Test func refreshDoesNotRestartPendingLocalCostScan() async throws {
    let localCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let estimator = CountingDelayedCostEstimator(cost: localCost, delay: .milliseconds(250))
    // startsAutomatically: false so the background timer's own refresh() can't
    // race the explicit refreshes below — otherwise two refreshes can each
    // start a cost scan before the pending-scan dedup registers, which is the
    // exact invariant under test. Drive every refresh explicitly instead.
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: estimator,
      startsAutomatically: false
    )

    await store.refresh() // starts the quota snapshot + the pending cost scan
    _ = try await Self.waitForSnapshot(in: store, attempts: 10)
    await store.refresh() // must NOT restart the still-pending cost scan

    let snapshot = try await Self.waitForCost(in: store, matching: localCost)
    #expect(snapshot.cost == localCost)
    #expect(await estimator.callCount == 1)
  }

  private static let day = Date(timeIntervalSince1970: 1_783_478_400)

  private static func descriptor(cost: CostSummary) -> ProviderDescriptor {
    ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in
        [StubUsageStrategy(cost: cost)]
      }
    )
  }

  private static func costSummary(
    todaySpend: Double,
    monthSpend: Double,
    monthTokens: Int,
    latestTokens: Int,
    sourceDescription: String = "Estimated from local logs",
    daily: [DailyCost]
  ) -> CostSummary {
    CostSummary(
      todaySpend: todaySpend,
      monthSpend: monthSpend,
      monthTokens: monthTokens,
      latestTokens: latestTokens,
      topModel: "gpt-5",
      sourceDescription: sourceDescription,
      daily: daily
    )
  }

  private static func dailySeries(tokens: Int) -> [DailyCost] {
    [
      DailyCost(date: day.addingTimeInterval(-86400), spend: 0.50, tokens: tokens / 2),
      DailyCost(date: day, spend: 1.00, tokens: tokens / 2),
    ]
  }

  private static func waitForSnapshot(in store: UsageStore, attempts: Int = 100) async throws -> UsageSnapshot {
    for _ in 0 ..< attempts {
      if let snapshot = store.snapshots[.codex] {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return try #require(store.snapshots[.codex])
  }

  private static func waitForCost(in store: UsageStore, matching cost: CostSummary) async throws -> UsageSnapshot {
    for _ in 0 ..< 100 {
      if let snapshot = store.snapshots[.codex],
         snapshot.cost == cost {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let snapshot = try #require(store.snapshots[.codex])
    #expect(snapshot.cost == cost)
    return snapshot
  }
}

private struct StubCostEstimator: UsageCostEstimating {
  let cost: CostSummary

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    cost
  }
}

private struct DelayedCostEstimator: UsageCostEstimating {
  let cost: CostSummary
  let delay: Duration

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    try? await Task.sleep(for: delay)
    return cost
  }
}

private struct CachedThenDelayedCostEstimator: UsageCostEstimating {
  let cachedCost: CostSummary
  let freshCost: CostSummary
  let delay: Duration

  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary? {
    cachedCost
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    try? await Task.sleep(for: delay)
    return freshCost
  }
}

private actor CountingDelayedCostEstimator: UsageCostEstimating {
  let cost: CostSummary
  let delay: Duration
  private(set) var callCount = 0

  init(cost: CostSummary, delay: Duration) {
    self.cost = cost
    self.delay = delay
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    callCount += 1
    try? await Task.sleep(for: delay)
    return cost
  }
}

private struct StubUsageStrategy: ProviderFetchStrategy {
  let cost: CostSummary
  let id = "stub"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        cost: cost,
        updatedAt: cost.daily.last?.date ?? context.now
      ),
      sourceLabel: "Stub"
    )
  }
}
