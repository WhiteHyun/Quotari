import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreLocalCostReviewTests {
  @Test func mockProviderCostIsReplacedByLocalCost() async throws {
    let mockCost = Self.costSummary(
      todaySpend: 9.00,
      monthSpend: 18.00,
      monthTokens: 9000,
      latestTokens: 900,
      sourceDescription: "Mock",
      daily: Self.dailySeries(tokens: 9000)
    )
    let localCost = Self.costSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      daily: Self.dailySeries(tokens: 1000)
    )
    let store = UsageStore(
      providers: [Self.descriptor(cost: mockCost, kind: .mock)],
      costEstimator: ReviewStubCostEstimator(cost: localCost)
    )

    let snapshot = try await Self.waitForCost(in: store, matching: localCost)

    #expect(snapshot.cost == localCost)
  }

  @Test func emptyLocalCostScanClearsPreviousLocalChart() async throws {
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
    let estimator = ReviewSequenceCostEstimator(costs: [localCost, nil])
    let store = UsageStore(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: estimator
    )

    _ = try await Self.waitForCost(in: store, matching: localCost)
    await store.refresh()

    let snapshot = try await Self.waitForCostCleared(in: store)
    #expect(snapshot.cost == nil)
  }

  private static let day = Date(timeIntervalSince1970: 1_783_478_400)

  private static func descriptor(cost: CostSummary, kind: ProviderFetchKind = .api) -> ProviderDescriptor {
    ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in
        [ReviewUsageStrategy(cost: cost, kind: kind)]
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

  private static func waitForCostCleared(in store: UsageStore) async throws -> UsageSnapshot {
    for _ in 0 ..< 100 {
      if let snapshot = store.snapshots[.codex],
         snapshot.cost == nil
      {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let snapshot = try #require(store.snapshots[.codex])
    #expect(snapshot.cost == nil)
    return snapshot
  }
}

private struct ReviewStubCostEstimator: UsageCostEstimating {
  let cost: CostSummary

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    cost
  }
}

private actor ReviewSequenceCostEstimator: UsageCostEstimating {
  private var costs: [CostSummary?]

  init(costs: [CostSummary?]) {
    self.costs = costs
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    guard !costs.isEmpty else { return nil }
    return costs.removeFirst()
  }
}

private struct ReviewUsageStrategy: ProviderFetchStrategy {
  let cost: CostSummary
  let kind: ProviderFetchKind
  let id = "review-usage"

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
