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
    let store = UsageStore(
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
    let store = UsageStore(
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
    let store = UsageStore(
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
    let store = UsageStore(
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
    let store = UsageStore(
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
    let store = UsageStore(
      providers: [Self.descriptor(cost: reportedCost)],
      costEstimator: estimator
    )

    _ = try await Self.waitForSnapshot(in: store, attempts: 10)
    await store.refresh()
    await store.refresh()

    let snapshot = try await Self.waitForCost(in: store, matching: localCost)
    #expect(snapshot.cost == localCost)
    #expect(await estimator.callCount == 1)
  }

  @Test func refreshUsesPersistedSelectedAccount() async throws {
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Selected",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    try selectionStore.save([.codex: account])
    let recorder = AccountRecorder()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: recorder)] }
    )
    let store = UsageStore(
      providers: [descriptor],
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.refresh()

    #expect(await recorder.accounts == [account])
  }

  @Test func accountSwitchRejectsInFlightRefreshAndFetchesSelectedAccount() async throws {
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let firstAccount = ProviderAccount(
      provider: .codex,
      displayName: "First",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/tmp/first/auth.json")
    )
    let selectedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Selected",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/tmp/selected/auth.json")
    )
    try selectionStore.save([.codex: firstAccount])
    let strategy = AccountSwitchRaceStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    let initialRefresh = Task { await store.refresh() }
    await strategy.waitUntilFirstRequestStarts()
    store.selectAccount(selectedAccount, for: .codex)
    let selectedSnapshot = await Self.waitForSnapshot(
      in: store,
      account: selectedAccount.displayName,
      attempts: 10
    )
    let requestCountBeforeStaleRequestFinishes = await strategy.requestCount
    await strategy.resumeFirstRequest()
    await initialRefresh.value

    #expect(selectedSnapshot?.account == "Selected")
    #expect(selectedSnapshot?.primary?.usedPercent == 20)
    #expect(requestCountBeforeStaleRequestFinishes == 2)
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

  private static func waitForSnapshot(
    in store: UsageStore,
    account: String,
    attempts: Int
  ) async -> UsageSnapshot? {
    for _ in 0 ..< attempts {
      if let snapshot = store.snapshots[.codex], snapshot.account == account {
        return snapshot
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
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

private struct StubCostEstimator: UsageCostEstimating {
  let cost: CostSummary

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    cost
  }
}

private struct EmptyCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
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
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}

private actor AccountRecorder {
  private(set) var accounts: [ProviderAccount?] = []

  func record(_ account: ProviderAccount?) {
    accounts.append(account)
  }
}

private struct RecordingAccountStrategy: ProviderFetchStrategy {
  let recorder: AccountRecorder
  let id = "recording"
  let kind = ProviderFetchKind.mock

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    await recorder.record(context.account)
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}

private actor AccountSwitchRaceStrategy: ProviderFetchStrategy {
  let id = "account-switch-race"
  let kind = ProviderFetchKind.api

  private(set) var requestCount = 0
  private var firstRequestContinuation: CheckedContinuation<Void, Never>?
  private var firstRequestStartedContinuation: CheckedContinuation<Void, Never>?

  func waitUntilFirstRequestStarts() async {
    guard requestCount == 0 else { return }
    await withCheckedContinuation { continuation in
      firstRequestStartedContinuation = continuation
    }
  }

  func resumeFirstRequest() {
    firstRequestContinuation?.resume()
    firstRequestContinuation = nil
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let isFirstRequest = requestCount == 0
    requestCount += 1
    if isFirstRequest {
      firstRequestStartedContinuation?.resume()
      firstRequestStartedContinuation = nil
      await withCheckedContinuation { continuation in
        firstRequestContinuation = continuation
      }
    }

    let isSelected = context.account?.displayName == "Selected"
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        account: context.account?.displayName,
        primary: RateWindow(kind: .session, usedPercent: isSelected ? 20 : 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-usage-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
