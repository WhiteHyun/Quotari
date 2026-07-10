import AppKit
import Observation
import QuotariCore
import SwiftUI

@MainActor
@Observable
final class UsageStore {
  private(set) var snapshots: [UsageProvider: UsageSnapshot] = [:]
  private(set) var errors: [UsageProvider: String] = [:]
  private(set) var sourceLabels: [UsageProvider: String] = [:]
  private(set) var accounts: [UsageProvider: [ProviderAccount]] = [:]
  private(set) var selectedAccounts: [UsageProvider: ProviderAccount] = [:]
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?

  var refreshInterval: TimeInterval = 60 {
    didSet { startTimer() }
  }

  var iconStyle: MenuBarIconStyle =
    .init(rawValue: UserDefaults.standard.string(forKey: UsageStore.iconStyleKey) ?? "") ?? .gauge {
    didSet {
      UserDefaults.standard.set(iconStyle.rawValue, forKey: Self.iconStyleKey)
    }
  }

  private static let iconStyleKey = "menuBarIconStyle"
  private static let localCostScanThrottle: TimeInterval = 15 * 60

  let providers: [ProviderDescriptor]
  private let costEstimator: any UsageCostEstimating
  private let accountDiscovery: any ProviderAccountDiscovering
  private let accountSelectionStore: ProviderAccountSelectionStore

  private var timerTask: Task<Void, Never>?
  private var refreshRequested = false
  private var accountRevisions: [UsageProvider: UInt] = [:]
  private var costTasks: [UsageProvider: Task<Void, Never>] = [:]
  private var lastCostScans: [UsageProvider: Date] = [:]
  private var lastEmptyCostScans: [UsageProvider: Date] = [:]
  private var latestReportedCostFallbacks: [UsageProvider: ReportedCostFallback] = [:]

  private struct ReportedCostFallback {
    let cost: CostSummary?
  }

  /// Tests inject mock descriptors so results don't depend on credentials
  /// present on the machine running them.
  init(
    providers: [ProviderDescriptor] = ProviderRegistry.all,
    costEstimator: any UsageCostEstimating = LocalUsageCostEstimator(),
    accountDiscovery: any ProviderAccountDiscovering = ProviderAccountDiscovery(),
    accountSelectionStore: ProviderAccountSelectionStore = ProviderAccountSelectionStore(),
    startsAutomatically: Bool = true
  ) {
    assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
    self.providers = providers
    self.costEstimator = costEstimator
    self.accountDiscovery = accountDiscovery
    self.accountSelectionStore = accountSelectionStore
    selectedAccounts = accountSelectionStore.load()
    if startsAutomatically {
      startTimer()
      Task { await reloadAccounts() }
    }
  }

  func refresh() async {
    guard !isRefreshing else {
      refreshRequested = true
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }

    repeat {
      refreshRequested = false
      await performRefresh()
    } while refreshRequested
  }

  private func performRefresh() async {
    let now = Date()
    await withTaskGroup(of: (UsageProvider, UInt, Result<ProviderFetchResult, Error>).self) { group in
      for descriptor in providers {
        let account = selectedAccounts[descriptor.id]
        let revision = accountRevisions[descriptor.id] ?? 0
        group.addTask { await (descriptor.id, revision, descriptor.fetch(now: now, account: account)) }
      }
      for await (provider, revision, result) in group {
        guard (accountRevisions[provider] ?? 0) == revision else { continue }
        apply(provider: provider, result: result)
      }
    }
    lastRefresh = Date()
  }

  private func refresh(provider: UsageProvider) async {
    guard let descriptor = providers.first(where: { $0.id == provider }) else { return }
    let account = selectedAccounts[provider]
    let revision = accountRevisions[provider] ?? 0
    let result = await descriptor.fetch(now: Date(), account: account)
    guard (accountRevisions[provider] ?? 0) == revision else { return }
    apply(provider: provider, result: result)
    lastRefresh = Date()
  }

  func reloadAccounts() async {
    var next: [UsageProvider: [ProviderAccount]] = [:]
    var refreshedSelections: [(UsageProvider, ProviderAccount)] = []
    for descriptor in providers {
      var providerAccounts = await accountDiscovery.accounts(for: descriptor.id)
      if let selected = selectedAccounts[descriptor.id] {
        if let refreshed = providerAccounts.first(where: { $0.id == selected.id }) {
          if refreshed != selected {
            refreshedSelections.append((descriptor.id, refreshed))
          }
        } else {
          providerAccounts.append(selected)
        }
      }
      next[descriptor.id] = providerAccounts
    }
    accounts = next
    for (provider, account) in refreshedSelections {
      selectAccount(account, for: provider)
    }
  }

  func selectAccount(id: String?, for provider: UsageProvider) {
    let account = id.flatMap { id in accounts[provider]?.first { $0.id == id } }
    selectAccount(account, for: provider)
  }

  func selectAccount(_ account: ProviderAccount?, for provider: UsageProvider) {
    guard selectedAccounts[provider] != account else { return }
    if let account {
      selectedAccounts[provider] = account
    } else {
      selectedAccounts[provider] = nil
    }
    accountRevisions[provider, default: 0] &+= 1
    try? accountSelectionStore.save(selectedAccounts)
    snapshots[provider] = nil
    errors[provider] = nil
    sourceLabels[provider] = nil
    costTasks[provider]?.cancel()
    costTasks[provider] = nil
    lastCostScans[provider] = nil
    lastEmptyCostScans[provider] = nil
    latestReportedCostFallbacks[provider] = nil
    Task { await refresh(provider: provider) }
  }
}

private extension UsageStore {
  private func apply(provider: UsageProvider, result: Result<ProviderFetchResult, Error>) {
    switch result {
    case let .success(value):
      let hidesProviderCost = Self.shouldHideProviderCost(provider: provider, sourceKind: value.sourceKind)
      let reportedCostFallback = Self.reportedCostFallback(
        from: value.usage.cost,
        hidesProviderCost: hidesProviderCost
      )
      let needsLocalCost = Self.shouldUseLocalCost(
        provider: provider,
        existing: value.usage.cost,
        sourceKind: value.sourceKind
      )
      let account = selectedAccounts[provider]
      let cachedCost = needsLocalCost
        ? costEstimator.cachedCostSummary(
          provider: provider,
          account: account,
          now: value.usage.updatedAt,
          historyDays: 30
        )
        : nil
      snapshots[provider] = Self.displaySnapshot(
        from: value.usage,
        previous: snapshots[provider],
        cachedCost: cachedCost,
        prefersLocalCost: needsLocalCost,
        hidesProviderCost: hidesProviderCost
      )
      sourceLabels[provider] = value.sourceLabel
      errors[provider] = nil
      if needsLocalCost {
        refreshCost(
          provider: provider,
          account: account,
          now: value.usage.updatedAt,
          reportedCostFallback: reportedCostFallback,
          cacheHit: cachedCost != nil
        )
      } else {
        lastEmptyCostScans[provider] = nil
        latestReportedCostFallbacks[provider] = nil
        costTasks[provider]?.cancel()
        costTasks[provider] = nil
      }
    case let .failure(error):
      errors[provider] = error.localizedDescription // keep any prior snapshot
    }
  }

  private nonisolated static func displaySnapshot(
    from snapshot: UsageSnapshot,
    previous: UsageSnapshot?,
    cachedCost: CostSummary?,
    prefersLocalCost: Bool,
    hidesProviderCost: Bool
  ) -> UsageSnapshot {
    guard prefersLocalCost else { return snapshot }
    var display = snapshot
    display.cost = cachedCost
      ?? previous?.cost.flatMap { shouldCarryForwardCost($0) ? $0 : nil }
      ?? snapshot.cost.flatMap { hidesProviderCost || shouldHideSparseReportedCost($0) ? nil : $0 }
    return display
  }

  private nonisolated static func shouldUseLocalCost(
    provider: UsageProvider,
    existing cost: CostSummary?,
    sourceKind: ProviderFetchKind?
  ) -> Bool {
    if shouldHideProviderCost(provider: provider, sourceKind: sourceKind) {
      return true
    }
    return shouldUseLocalCost(existing: cost)
  }

  private nonisolated static func shouldUseLocalCost(existing cost: CostSummary?) -> Bool {
    guard let cost else { return true }
    return !cost.hasTokenMetrics || cost.daily.count <= 1
  }

  private nonisolated static func shouldCarryForwardCost(_ cost: CostSummary) -> Bool {
    cost.sourceDescription.localizedCaseInsensitiveContains("local")
  }

  private nonisolated static func shouldHideProviderCost(
    provider: UsageProvider,
    sourceKind: ProviderFetchKind?
  ) -> Bool {
    sourceKind == .mock && provider != .glm
  }

  private nonisolated static func shouldHideSparseReportedCost(_ cost: CostSummary) -> Bool {
    !cost.hasTokenMetrics && cost.daily.count <= 1 && cost.monthSpend == 0 && cost.todaySpend == 0
  }

  private nonisolated static func reportedCostFallback(
    from cost: CostSummary?,
    hidesProviderCost: Bool
  ) -> CostSummary? {
    guard !hidesProviderCost,
          let cost,
          !cost.sourceDescription.localizedCaseInsensitiveContains("local"),
          !shouldHideSparseReportedCost(cost)
    else { return nil }
    return cost
  }

  private func refreshCost(
    provider: UsageProvider,
    account: ProviderAccount?,
    now: Date,
    reportedCostFallback: CostSummary?,
    cacheHit: Bool
  ) {
    latestReportedCostFallbacks[provider] = ReportedCostFallback(cost: reportedCostFallback)
    guard costTasks[provider] == nil else { return }
    if let lastEmptyCostScan = lastEmptyCostScans[provider],
       now.timeIntervalSince(lastEmptyCostScan) < Self.localCostScanThrottle {
      return
    }
    if cacheHit,
       let lastCostScan = lastCostScans[provider],
       now.timeIntervalSince(lastCostScan) < Self.localCostScanThrottle {
      return
    }
    lastCostScans[provider] = now
    let revision = accountRevisions[provider] ?? 0
    let costEstimator = costEstimator
    costTasks[provider] = Task { [weak self] in
      let cost = await costEstimator.costSummary(
        provider: provider,
        account: account,
        now: now,
        historyDays: 30
      )
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.finishCostRefresh(
          cost,
          provider: provider,
          account: account,
          revision: revision
        )
      }
    }
  }

  private func finishCostRefresh(
    _ cost: CostSummary?,
    provider: UsageProvider,
    account: ProviderAccount?,
    revision: UInt
  ) {
    guard (accountRevisions[provider] ?? 0) == revision else { return }
    costTasks[provider] = nil
    guard let cost else {
      lastEmptyCostScans[provider] = Date()
      costEstimator.invalidateCachedCostSummary(
        provider: provider,
        account: account,
        historyDays: 30
      )
      let reportedCostFallback = latestReportedCostFallbacks[provider]?.cost
      clearLocalCost(provider: provider, reportedCostFallback: reportedCostFallback)
      return
    }
    lastEmptyCostScans[provider] = nil
    applyCost(cost, provider: provider)
  }

  private func applyCost(_ cost: CostSummary, provider: UsageProvider) {
    guard var snapshot = snapshots[provider],
          Self.canApplyLocalCost(over: snapshot.cost)
    else { return }
    snapshot.cost = cost
    snapshots[provider] = snapshot
  }

  private func clearLocalCost(provider: UsageProvider, reportedCostFallback: CostSummary?) {
    guard var snapshot = snapshots[provider],
          let cost = snapshot.cost,
          cost.sourceDescription.localizedCaseInsensitiveContains("local")
    else { return }
    snapshot.cost = reportedCostFallback
    snapshots[provider] = snapshot
  }

  private nonisolated static func canApplyLocalCost(over cost: CostSummary?) -> Bool {
    guard let cost else { return true }
    return shouldUseLocalCost(existing: cost) || cost.sourceDescription.localizedCaseInsensitiveContains("local")
  }

  private func startTimer() {
    timerTask?.cancel()
    timerTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        await refresh()
        let interval = refreshInterval
        try? await Task.sleep(for: .seconds(interval))
      }
    }
  }
}

extension UsageStore {
  var highestUsedPercent: Double {
    snapshots.values.map(\.highestUsedPercent).max() ?? 0
  }

  var menuBarIcon: NSImage {
    IconRenderer.gaugeIcon(
      usedPercent: highestUsedPercent,
      loading: isRefreshing && snapshots.isEmpty,
      style: iconStyle
    )
  }

  var menuBarAccessibilityLabel: String {
    guard !snapshots.isEmpty else { return "Quotari, loading usage" }
    let percent = Int(highestUsedPercent.rounded())
    return "Quotari, highest usage \(percent) percent, \(Theme.statusWord(highestUsedPercent))"
  }
}
