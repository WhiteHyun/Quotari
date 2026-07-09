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
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?

  var refreshInterval: TimeInterval = 60 {
    didSet { startTimer() }
  }

  var iconStyle: MenuBarIconStyle =
    .init(rawValue: UserDefaults.standard.string(forKey: UsageStore.iconStyleKey) ?? "") ?? .gauge
  {
    didSet {
      UserDefaults.standard.set(iconStyle.rawValue, forKey: Self.iconStyleKey)
    }
  }

  private static let iconStyleKey = "menuBarIconStyle"

  let providers: [ProviderDescriptor]
  private let costEstimator: any UsageCostEstimating

  private var timerTask: Task<Void, Never>?
  private var costTasks: [UsageProvider: Task<Void, Never>] = [:]

  /// Tests inject mock descriptors so results don't depend on credentials
  /// present on the machine running them.
  init(
    providers: [ProviderDescriptor] = ProviderRegistry.all,
    costEstimator: any UsageCostEstimating = LocalUsageCostEstimator()
  ) {
    assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
    self.providers = providers
    self.costEstimator = costEstimator
    startTimer()
  }

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    let now = Date()
    await withTaskGroup(of: (UsageProvider, Result<ProviderFetchResult, Error>).self) { group in
      for descriptor in providers {
        group.addTask { await (descriptor.id, descriptor.fetch(now: now)) }
      }
      for await (provider, result) in group {
        apply(provider: provider, result: result)
      }
    }
    lastRefresh = Date()
  }

  private func apply(provider: UsageProvider, result: Result<ProviderFetchResult, Error>) {
    switch result {
    case let .success(value):
      let needsLocalCost = Self.shouldUseLocalCost(
        provider: provider,
        existing: value.usage.cost,
        sourceKind: value.sourceKind
      )
      let cachedCost = needsLocalCost
        ? costEstimator.cachedCostSummary(provider: provider, now: value.usage.updatedAt, historyDays: 30)
        : nil
      snapshots[provider] = Self.displaySnapshot(
        from: value.usage,
        previous: snapshots[provider],
        cachedCost: cachedCost,
        prefersLocalCost: needsLocalCost,
        hidesProviderCost: Self.shouldHideProviderCost(provider: provider, sourceKind: value.sourceKind)
      )
      sourceLabels[provider] = value.sourceLabel
      errors[provider] = nil
      if needsLocalCost {
        refreshCost(provider: provider, now: value.usage.updatedAt)
      } else {
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
    !shouldUseLocalCost(existing: cost) || cost.sourceDescription.localizedCaseInsensitiveContains("local")
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

  private func refreshCost(provider: UsageProvider, now: Date) {
    guard costTasks[provider] == nil else { return }
    let costEstimator = costEstimator
    costTasks[provider] = Task { [weak self] in
      let cost = await costEstimator.costSummary(provider: provider, now: now, historyDays: 30)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.finishCostRefresh(cost, provider: provider)
      }
    }
  }

  private func finishCostRefresh(_ cost: CostSummary?, provider: UsageProvider) {
    costTasks[provider] = nil
    guard let cost else {
      clearLocalCost(provider: provider)
      return
    }
    applyCost(cost, provider: provider)
  }

  private func applyCost(_ cost: CostSummary, provider: UsageProvider) {
    guard var snapshot = snapshots[provider],
          Self.canApplyLocalCost(over: snapshot.cost)
    else { return }
    snapshot.cost = cost
    snapshots[provider] = snapshot
  }

  private func clearLocalCost(provider: UsageProvider) {
    guard var snapshot = snapshots[provider],
          let cost = snapshot.cost,
          cost.sourceDescription.localizedCaseInsensitiveContains("local")
    else { return }
    snapshot.cost = nil
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
