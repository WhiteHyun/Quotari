import AppKit
import Observation
import QuotariCore
import SwiftUI

@MainActor
@Observable
final class UsageStore {
  var snapshots: [UsageProvider: UsageSnapshot] = [:]
  var errors: [UsageProvider: String] = [:]
  var sourceLabels: [UsageProvider: String] = [:]
  private(set) var accounts: [UsageProvider: [ProviderAccount]] = [:]
  private(set) var selectedAccounts: [UsageProvider: ProviderAccount] = [:]
  /// Live accounts whose identity already has a (hidden) saved registry copy.
  private(set) var capturedEquivalentIDs: Set<String> = []
  var accountUsage: [UsageProvider: [String: ProviderAccountUsage]] = [:]
  var refreshingAccountUsageProviders = Set<UsageProvider>()
  private(set) var isRefreshing = false
  private(set) var lastRefresh: Date?

  var refreshInterval: TimeInterval {
    didSet {
      defaults.set(refreshInterval, forKey: Self.refreshIntervalDefaultsKey)
      startTimer()
    }
  }

  static let localCostScanThrottle: TimeInterval = 15 * 60
  static let refreshIntervalDefaultsKey = "refreshIntervalSeconds"
  static let refreshIntervalRange: ClosedRange<TimeInterval> = 60 ... 1800

  let providers: [ProviderDescriptor]
  let costEstimator: any UsageCostEstimating
  let accountDiscovery: any ProviderAccountDiscovering
  private let accountSelectionStore: ProviderAccountSelectionStore
  private let accountCapture: AccountCaptureService
  private let defaults: UserDefaults
  var captureErrors: [UsageProvider: String] = [:]

  private(set) var timerTask: Task<Void, Never>?
  private var refreshRequested = false
  private(set) var accountRevisions: [UsageProvider: UInt] = [:]
  var costTasks: [UsageProvider: Task<Void, Never>] = [:]
  var lastCostScans: [UsageProvider: Date] = [:]
  var lastEmptyCostScans: [UsageProvider: Date] = [:]
  var latestReportedCostFallbacks: [UsageProvider: ReportedCostFallback] = [:]
  var accountUsageRefreshTasks: [UsageProvider: AccountUsageRefreshTask] = [:]

  /// Tests inject mock descriptors so results don't depend on credentials
  /// present on the machine running them.
  init(
    providers: [ProviderDescriptor] = ProviderRegistry.all,
    costEstimator: any UsageCostEstimating = LocalUsageCostEstimator(),
    accountDiscovery: any ProviderAccountDiscovering = ProviderAccountDiscovery(),
    accountSelectionStore: ProviderAccountSelectionStore = ProviderAccountSelectionStore(),
    accountCapture: AccountCaptureService = AccountCaptureService(),
    defaults: UserDefaults = .standard,
    startsAutomatically: Bool = true
  ) {
    assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
    self.providers = providers
    self.costEstimator = costEstimator
    self.accountDiscovery = accountDiscovery
    self.accountSelectionStore = accountSelectionStore
    self.accountCapture = accountCapture
    self.defaults = defaults
    selectedAccounts = accountSelectionStore.load()
    // refreshInterval has no inline default: its first assignment runs the
    // @Observable-generated init accessor instead of the setter, so restoring
    // here neither rewrites defaults nor starts the timer via didSet.
    let savedInterval = defaults.double(forKey: Self.refreshIntervalDefaultsKey)
    let range = Self.refreshIntervalRange
    refreshInterval = savedInterval > 0
      ? min(max(savedInterval, range.lowerBound), range.upperBound)
      : 60
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
    await withTaskGroup(
      of: (UsageProvider, ProviderAccount?, UInt, Result<ProviderFetchResult, Error>).self
    ) { group in
      for descriptor in providers {
        let account = selectedAccounts[descriptor.id]
        let revision = accountRevisions[descriptor.id] ?? 0
        group.addTask {
          await (descriptor.id, account, revision, descriptor.fetch(now: now, account: account))
        }
      }
      for await (provider, account, revision, result) in group {
        guard (accountRevisions[provider] ?? 0) == revision else { continue }
        apply(provider: provider, account: account, result: result)
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
    apply(provider: provider, account: account, result: result)
    lastRefresh = Date()
  }

  func reloadAccounts() async {
    var next: [UsageProvider: [ProviderAccount]] = [:]
    var refreshedSelections: [(UsageProvider, ProviderAccount)] = []
    var alreadyCaptured: Set<String> = []
    for descriptor in providers {
      let previousAccounts = accounts[descriptor.id] ?? []
      var providerAccounts = await accountDiscovery.accounts(for: descriptor.id)
      if let selected = selectedAccounts[descriptor.id],
         let updated = await reconciledSelection(selected, in: &providerAccounts) {
        refreshedSelections.append((descriptor.id, updated))
      }
      reconcileAccountUsage(
        provider: descriptor.id,
        previousAccounts: previousAccounts,
        currentAccounts: providerAccounts
      )
      await alreadyCaptured.formUnion(
        accountDiscovery.accountsWithCapturedCopies(among: providerAccounts)
      )
      next[descriptor.id] = providerAccounts
    }
    accounts = next
    capturedEquivalentIDs = alreadyCaptured
    for (provider, account) in refreshedSelections {
      selectAccount(account, for: provider)
    }
  }

  func selectAccount(id: String?, for provider: UsageProvider) {
    let account = id.flatMap { id in accounts[provider]?.first { $0.id == id } }
    selectAccount(account, for: provider)
  }

  /// Snapshots the account's live credentials into Quotari's own registry so
  /// it survives the CLI credential slot being reused by another login. The
  /// keychain/file I/O runs off the main actor so a slow (or prompting)
  /// `security` call can't freeze the popover.
  func captureAccount(_ account: ProviderAccount) async {
    let capture = accountCapture
    let now = Date()
    do {
      try await Task.detached { try capture.capture(account, now: now) }.value
      captureErrors[account.provider] = nil
      await reloadAccounts()
    } catch {
      captureErrors[account.provider] = error.localizedDescription
    }
  }

  func removeCapturedAccount(_ account: ProviderAccount) async {
    guard case let .quotariRegistry(id) = account.credentialSource else { return }
    let capture = accountCapture
    do {
      try await Task.detached { try capture.remove(id: id) }.value
      captureErrors[account.provider] = nil
      if selectedAccounts[account.provider]?.id == account.id {
        selectAccount(nil, for: account.provider)
      }
      await reloadAccounts()
    } catch {
      captureErrors[account.provider] = error.localizedDescription
    }
  }

  func selectAccount(_ account: ProviderAccount?, for provider: UsageProvider) {
    guard selectedAccounts[provider] != account else { return }
    let cachedUsage = account.flatMap { accountUsage[provider]?[$0.id] }
    if let account {
      selectedAccounts[provider] = account
    } else {
      selectedAccounts[provider] = nil
    }
    accountRevisions[provider, default: 0] &+= 1
    try? accountSelectionStore.save(selectedAccounts)
    applyCachedAccountUsage(cachedUsage, account: account, provider: provider)
    costTasks[provider]?.cancel()
    costTasks[provider] = nil
    lastCostScans[provider] = nil
    lastEmptyCostScans[provider] = nil
    latestReportedCostFallbacks[provider] = nil
    Task { await refresh(provider: provider) }
  }
}

private extension UsageStore {
  private func apply(
    provider: UsageProvider,
    account: ProviderAccount?,
    result: Result<ProviderFetchResult, Error>
  ) {
    switch result {
    case let .success(value):
      applySuccessfulFetch(value, provider: provider, account: account)
    case let .failure(error):
      errors[provider] = error.localizedDescription // keep any prior snapshot
      recordAccountUsageFailure(error, provider: provider, account: account)
    }
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

  func menuBarIcon(frame: Int) -> NSImage {
    IconRenderer.mascotIcon(frame: frame)
  }

  var menuBarAnimationInterval: TimeInterval {
    IconRenderer.animationInterval(usedPercent: highestUsedPercent)
  }

  var menuBarAccessibilityLabel: String {
    guard !snapshots.isEmpty else { return "Quotari, loading usage" }
    let remaining = Int((100 - highestUsedPercent).rounded())
    return "Quotari, lowest remaining quota \(remaining) percent, \(Theme.statusWord(highestUsedPercent))"
  }
}
