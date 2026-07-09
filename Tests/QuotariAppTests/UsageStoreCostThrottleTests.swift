import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreCostThrottleTests {
  @Test func cachedLocalCostThrottlesRepeatedFreshScans() async throws {
    let cachedCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200
    )
    let freshCost = Self.costSummary(
      todaySpend: 2.00,
      monthSpend: 4.00,
      monthTokens: 2000,
      latestTokens: 400
    )
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let estimator = CountingCachedThrottleCostEstimator(cachedCost: cachedCost, freshCost: freshCost)
    let store = UsageStore(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: estimator
    )

    _ = try await Self.waitForCost(in: store, matching: freshCost)
    await store.refresh()
    try await Task.sleep(for: .milliseconds(50))

    #expect(estimator.callCount == 1)
    #expect(store.snapshots[UsageProvider.codex]?.cost == freshCost)
  }

  @Test func emptyLocalCostScanAttemptsAreThrottled() async throws {
    let reportedCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let estimator = CountingEmptyThrottleCostEstimator()
    let store = UsageStore(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: estimator
    )

    try await Self.waitForCallCount(in: estimator, matching: 1)
    try await Task.sleep(for: .milliseconds(50))
    await store.refresh()
    try await Task.sleep(for: .milliseconds(50))

    #expect(estimator.callCount == 1)
    #expect(store.snapshots[UsageProvider.codex]?.cost == nil)
  }

  private static let day = Date(timeIntervalSince1970: 1_783_478_400)

  private static func descriptor(cost: CostSummary) -> ProviderDescriptor {
    ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [ThrottleUsageStrategy(cost: cost)] }
    )
  }

  private static func costSummary(
    todaySpend: Double,
    monthSpend: Double,
    monthTokens: Int,
    latestTokens: Int
  ) -> CostSummary {
    CostSummary(
      todaySpend: todaySpend,
      monthSpend: monthSpend,
      monthTokens: monthTokens,
      latestTokens: latestTokens,
      topModel: "gpt-5",
      sourceDescription: "Estimated from local logs",
      daily: [
        DailyCost(date: day.addingTimeInterval(-86400), spend: 0.50, tokens: monthTokens / 2),
        DailyCost(date: day, spend: todaySpend, tokens: monthTokens / 2),
      ]
    )
  }

  private static func waitForCost(in store: UsageStore, matching cost: CostSummary) async throws -> UsageSnapshot {
    for _ in 0 ..< 100 {
      if let snapshot = store.snapshots[.codex],
         snapshot.cost == cost
      {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let snapshot = try #require(store.snapshots[.codex])
    #expect(snapshot.cost == cost)
    return snapshot
  }

  private static func waitForCallCount(
    in estimator: CountingEmptyThrottleCostEstimator,
    matching count: Int
  ) async throws {
    for _ in 0 ..< 100 {
      if estimator.callCount == count {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(estimator.callCount == count)
  }
}

private final class CountingCachedThrottleCostEstimator: @unchecked Sendable, UsageCostEstimating {
  private var cachedCost: CostSummary
  private let freshCost: CostSummary
  private(set) var callCount = 0

  init(cachedCost: CostSummary, freshCost: CostSummary) {
    self.cachedCost = cachedCost
    self.freshCost = freshCost
  }

  func cachedCostSummary(provider: UsageProvider, now: Date, historyDays: Int) -> CostSummary? {
    cachedCost
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    callCount += 1
    cachedCost = freshCost
    return freshCost
  }
}

private final class CountingEmptyThrottleCostEstimator: @unchecked Sendable, UsageCostEstimating {
  private(set) var callCount = 0

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    callCount += 1
    return nil
  }
}

private struct ThrottleUsageStrategy: ProviderFetchStrategy {
  let cost: CostSummary
  let id = "throttle"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        cost: cost,
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}
