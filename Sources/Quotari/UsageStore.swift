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
  /// The hidden saved registry copy behind each live account, keyed by the
  /// live account's id — identities that are saved while also being live.
  private(set) var capturedEquivalents: [String: ProviderAccount] = [:]
  /// The saved account a reconciled live selection stands in for; kept so the
  /// persisted selection stays on the saved account and a later slot reuse
  /// falls back to it instead of silently following the slot.
  var reconciledSelectionOrigins: [UsageProvider: ProviderAccount] = [:]
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
  let accountCapture: AccountCaptureService
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

    // A live stand-in can silently start pointing at a different login when
    // its CLI slot is reused; rediscover first so the timer path reconciles
    // the selection just like a manual reload.
    if !reconciledSelectionOrigins.isEmpty {
      await reloadAccounts()
    }
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
    // Hidden saved copies must track live-token rotations between account
    // reloads too — a slot swapped right after a rotation would otherwise
    // strand the copy on a consumed refresh token.
    await syncCapturedCopies(of: capturedCopyCandidates)
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
    var refreshedSelections: [(UsageProvider, SelectionUpdate)] = []
    var alreadyCaptured: [String: ProviderAccount] = [:]
    var syncCandidates: [ProviderAccount] = []
    for descriptor in providers {
      let previousAccounts = accounts[descriptor.id] ?? []
      var providerAccounts = await accountDiscovery.accounts(for: descriptor.id)
      if let selected = selectedAccounts[descriptor.id],
         let update = await reconciledSelection(
           selected,
           origin: reconciledSelectionOrigins[descriptor.id],
           in: &providerAccounts
         ) {
        refreshedSelections.append((descriptor.id, update))
      }
      reconcileAccountUsage(
        provider: descriptor.id,
        previousAccounts: previousAccounts,
        currentAccounts: providerAccounts
      )
      let flagged = await accountDiscovery.capturedCopies(among: providerAccounts)
      alreadyCaptured.merge(flagged) { current, _ in current }
      syncCandidates += providerAccounts.filter { flagged.keys.contains($0.id) }
      next[descriptor.id] = providerAccounts
    }
    accounts = next
    capturedEquivalents = alreadyCaptured
    for (provider, update) in refreshedSelections {
      selectAccount(update.account, for: provider, standingInFor: update.origin)
    }
    await syncCapturedCopies(of: syncCandidates)
  }

  /// `origin` is the saved account a reconciled live selection stands in for
  /// (nil for a direct user choice). The persisted selection always records
  /// the origin, so a relaunch — or a slot reused by another login — comes
  /// back to the account the user actually selected.
  func selectAccount(
    _ account: ProviderAccount?,
    for provider: UsageProvider,
    standingInFor origin: ProviderAccount?
  ) {
    let originChanged = reconciledSelectionOrigins[provider] != origin
    reconciledSelectionOrigins[provider] = origin
    guard selectedAccounts[provider] != account else {
      if originChanged {
        try? accountSelectionStore.save(persistableSelections())
      }
      return
    }
    let cachedUsage = account.flatMap { accountUsage[provider]?[$0.id] }
    if let account {
      selectedAccounts[provider] = account
    } else {
      selectedAccounts[provider] = nil
    }
    accountRevisions[provider, default: 0] &+= 1
    try? accountSelectionStore.save(persistableSelections())
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
