import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreCostCancellationTests {
  @Test func localCostRestartsAfterReportedCostCancelsPendingScan() async throws {
    let sparseCost = CostSummary(
      todaySpend: 0,
      monthSpend: 0,
      monthTokens: 0,
      latestTokens: 0,
      sourceDescription: "Reported by provider",
      daily: [DailyCost(date: Self.day, spend: 0, tokens: 0)]
    )
    let reportedCost = Self.costSummary(
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
    let estimator = CostCancellationGatedEstimator(cost: localCost)
    let store = UsageStore.isolatedForTesting(
      providers: [Self.descriptor(costs: [sparseCost, reportedCost, sparseCost])],
      costEstimator: estimator,
      startsAutomatically: false
    )

    await store.refresh()
    await estimator.waitUntilRequestCount(1)
    await store.refresh()
    await store.refresh()
    try await Task.sleep(for: .milliseconds(20))

    #expect(await estimator.requestCount == 1)
    await estimator.releaseNext()
    await estimator.waitUntilRequestCount(2)
    #expect(await estimator.maximumConcurrentRequests == 1)

    let replacementTask = store.costTasks[.codex]?.task
    await estimator.releaseNext()
    await replacementTask?.value

    #expect(store.snapshots[.codex]?.cost == localCost)
  }

  private static let day = Date(timeIntervalSince1970: 1_783_478_400)

  private static func descriptor(costs: [CostSummary]) -> ProviderDescriptor {
    let strategy = CostCancellationSequenceUsageStrategy(costs: costs)
    return ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
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
}

private actor CostCancellationSequenceUsageStrategy: ProviderFetchStrategy {
  nonisolated let id = "cost-cancellation-sequence-usage"
  nonisolated let kind = ProviderFetchKind.api
  private var costs: [CostSummary]

  init(costs: [CostSummary]) {
    self.costs = costs
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let cost = costs.count > 1 ? costs.removeFirst() : costs[0]
    return ProviderFetchResult(
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

private actor CostCancellationGatedEstimator: UsageCostEstimating {
  let cost: CostSummary
  private(set) var requestCount = 0
  private(set) var maximumConcurrentRequests = 0
  private var concurrentRequests = 0
  private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(cost: CostSummary) {
    self.cost = cost
  }

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    requestCount += 1
    concurrentRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
    let ready = requestCountWaiters.filter { requestCount >= $0.0 }
    requestCountWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    await withCheckedContinuation { releaseWaiters.append($0) }
    concurrentRequests -= 1
    return cost
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
