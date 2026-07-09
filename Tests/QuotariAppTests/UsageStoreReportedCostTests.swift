import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreReportedCostTests {
  @Test func nonzeroReportedCostIsDisplayedUntilLocalCostIsAvailable() async throws {
    let reportedCost = CostSummary(
      todaySpend: 3.70,
      monthSpend: 3.70,
      monthTokens: 0,
      latestTokens: 0,
      todaySpendLabel: "Reported",
      monthSpendLabel: "Period cost",
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 3.70, tokens: 0)]
    )
    let store = UsageStore(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: EmptyReportedCostEstimator()
    )

    let snapshot = try await Self.waitForSnapshot(in: store)
    #expect(snapshot.cost == reportedCost)

    try await Task.sleep(for: .milliseconds(100))
    #expect(store.snapshots[.codex]?.cost == reportedCost)
  }

  @Test func zeroReportedCostIsHiddenWhileLocalCostLoads() async throws {
    let localCost = CostSummary(
      todaySpend: 1.25,
      monthSpend: 2.50,
      monthTokens: 1000,
      latestTokens: 200,
      topModel: "gpt-5",
      sourceDescription: "Estimated from local logs",
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
    let store = UsageStore(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: DelayedReportedCostEstimator(cost: localCost, delay: .milliseconds(250))
    )

    let initial = try await Self.waitForSnapshot(in: store, attempts: 10)
    #expect(initial.primary?.usedPercent == 10)
    #expect(initial.cost == nil)

    let updated = try await Self.waitForCost(in: store, matching: localCost)
    #expect(updated.cost == localCost)
  }

  private static let day = Date(timeIntervalSince1970: 1_783_478_400)

  private static func descriptor(cost: CostSummary) -> ProviderDescriptor {
    ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [ReportedCostStrategy(cost: cost)] }
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
}

private struct EmptyReportedCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}

private struct DelayedReportedCostEstimator: UsageCostEstimating {
  let cost: CostSummary
  let delay: Duration

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    try? await Task.sleep(for: delay)
    return cost
  }
}

private struct ReportedCostStrategy: ProviderFetchStrategy {
  let cost: CostSummary
  let id = "reported-cost"
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
