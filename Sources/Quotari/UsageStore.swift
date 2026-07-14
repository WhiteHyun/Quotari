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
  /// The most recent spawned dashboard refresh, so a credential-slot mutation
  /// (an account switch) can await any in-flight refresh — which can rotate
  /// and persist a live token — before reading and overwriting the slot.
  private(set) var inFlightRefresh: Task<Void, Never>?
  /// True while an account switch is writing a credential slot. Refreshes are
  /// suppressed for the window so none rotates/persists a slot the switch is
  /// mid-way through reading and overwriting. This coordinates Quotari's own
  /// work only; a separately-running CLI must be stopped by the user.
  /// Set by the switch flow (in a sibling extension), so not `private(set)`.
  var isSwitching = false

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
  let accountSwitch: AccountSwitchService
  let profileFetcher: any ClaudeProfileFetching
  let profileStore: ClaudeProfileStore
  let quotaNotifications: QuotaNotificationController
  let codexCredentialLoader: @Sendable (ProviderCredentialSource) -> CodexCredentials?
  let claudeCredentialLoader: @Sendable (ProviderCredentialSource) -> ClaudeCredentials?
  private let defaults: UserDefaults
  var captureErrors: [UsageProvider: String] = [:]
  /// Fetched Claude account profiles keyed by `ProviderAccount.id`, used to
  /// label accounts by email. Loaded from disk at launch, refreshed lazily.
  var claudeProfiles: [String: ClaudeProfile] = [:]
  var profileFetchTasks: Set<String> = []
  /// The credential fingerprint most recently *attempted* for each account id
  /// (whether it succeeded or not). Keyed so a re-login or token rotation
  /// changes the fingerprint and triggers exactly one fresh attempt, while a
  /// persistent failure for one credential isn't retried on every reload.
  var profileFetchAttempts: [String: String] = [:]
  /// Successful empty profile responses keyed by account id and credential
  /// fingerprint. They distinguish a completed identity lookup from one that
  /// is still in flight, so deferred alerts can be drained as unattributed.
  var emptyClaudeProfileFingerprints: [String: String] = [:]

  private(set) var timerTask: Task<Void, Never>?
  private var refreshRequested = false
  var accountRevisions: [UsageProvider: UInt] = [:]
  var costTasks: [UsageProvider: Task<Void, Never>] = [:]
  var lastCostScans: [UsageProvider: Date] = [:]
  var lastEmptyCostScans: [UsageProvider: Date] = [:]
  var latestReportedCostFallbacks: [UsageProvider: ReportedCostFallback] = [:]
  var accountUsageRefreshTasks: [UsageProvider: AccountUsageRefreshTask] = [:]
  var providerFetchTasks: [UsageProvider: ProviderFetchTask] = [:]
  /// The fetch `selectAccount` starts, tracked so an account switch can await
  /// it (it may rotate/persist the live token the switch is about to back up).
  var selectionRefreshTasks: [UsageProvider: Task<Void, Never>] = [:]
  var quotaNotificationTask: Task<Void, Never>?
  var deferredClaudeQuotaNotification: DeferredClaudeQuotaNotification?

  /// Tests inject mock descriptors so results don't depend on credentials
  /// present on the machine running them.
  init(
    providers: [ProviderDescriptor] = ProviderRegistry.all,
    costEstimator: any UsageCostEstimating = LocalUsageCostEstimator(),
    accountDiscovery: any ProviderAccountDiscovering = ProviderAccountDiscovery(),
    accountSelectionStore: ProviderAccountSelectionStore = ProviderAccountSelectionStore(),
    accountCapture: AccountCaptureService = AccountCaptureService(),
    accountSwitch: AccountSwitchService = AccountSwitchService(),
    profileFetcher: any ClaudeProfileFetching = ClaudeProfileFetcher(),
    profileStore: ClaudeProfileStore = ClaudeProfileStore(),
    codexCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> CodexCredentials? = {
      try? CodexCredentialsStore.load(source: $0)
    },
    claudeCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> ClaudeCredentials? = {
      try? ClaudeCredentialsStore.load(source: $0)
    },
    defaults: UserDefaults = .standard,
    quotaNotifications: QuotaNotificationController? = nil,
    startsAutomatically: Bool = true
  ) {
    assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
    self.providers = providers
    self.costEstimator = costEstimator
    self.accountDiscovery = accountDiscovery
    self.accountSelectionStore = accountSelectionStore
    self.accountCapture = accountCapture
    self.accountSwitch = accountSwitch
    self.profileFetcher = profileFetcher
    self.profileStore = profileStore
    self.codexCredentialLoader = codexCredentialLoader
    self.claudeCredentialLoader = claudeCredentialLoader
    self.defaults = defaults
    self.quotaNotifications = quotaNotifications ?? QuotaNotificationController(defaults: defaults)
    selectedAccounts = accountSelectionStore.load()
    claudeProfiles = profileStore.load()
    // refreshInterval has no inline default: its first assignment runs the
    // @Observable-generated init accessor instead of the setter, so restoring
    // here neither rewrites defaults nor starts the timer via didSet.
    let savedInterval = defaults.double(forKey: Self.refreshIntervalDefaultsKey)
    let range = Self.refreshIntervalRange
    refreshInterval = savedInterval > 0
      ? min(max(savedInterval, range.lowerBound), range.upperBound)
      : 60
    // Seed attempts from the cache so a stable account isn't re-fetched on
    // every launch — only when its credential fingerprint changes.
    profileFetchAttempts = claudeProfiles.compactMapValues(\.fingerprint)
    if startsAutomatically {
      Task {
        _ = await self.quotaNotifications.refreshAuthorizationStatus()
        await reloadAccounts()
        startTimer()
      }
    }
  }

  private func performRefresh() async {
    let now = Date()
    await withTaskGroup(
      of: (UsageProvider, ProviderAccount?, UInt, Result<ProviderFetchResult, Error>).self
    ) { group in
      for descriptor in providers {
        let account = selectedAccounts[descriptor.id]
        let capturedRegistryID = capturedRegistryIDForFetch(
          provider: descriptor.id,
          selectedAccount: account
        )
        let revision = accountRevisions[descriptor.id] ?? 0
        group.addTask {
          await (
            descriptor.id,
            account,
            revision,
            self.serializedProviderFetch(
              descriptor: descriptor,
              now: now,
              account: account,
              capturedRegistryID: capturedRegistryID,
              expectedRevision: revision
            )
          )
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
    await syncCapturedCopies(of: capturedCopyCandidates.filter { isProviderEnabled($0.provider) })
  }

  func refresh(
    provider: UsageProvider,
    serializesProviderFetch: Bool = false
  ) async {
    // A superseded selection fetch (cancelled when the selection changed) or a
    // fetch that a switch has since started must not hit the network and
    // rotate a credential slot out from under the switch.
    guard !Task.isCancelled, !isSwitching, isProviderEnabled(provider),
          let descriptor = providers.first(where: { $0.id == provider })
    else { return }
    let account = selectedAccounts[provider]
    let capturedRegistryID = capturedRegistryIDForFetch(
      provider: provider,
      selectedAccount: account
    )
    let revision = accountRevisions[provider] ?? 0
    let now = Date()
    let result: Result<ProviderFetchResult, Error> = if serializesProviderFetch {
      await serializedProviderFetch(
        descriptor: descriptor,
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID,
        expectedRevision: revision
      )
    } else {
      await descriptor.fetch(
        now: now,
        account: account,
        capturedRegistryID: capturedRegistryID
      )
    }
    guard !Task.isCancelled,
          isProviderEnabled(provider),
          (accountRevisions[provider] ?? 0) == revision
    else { return }
    apply(provider: provider, account: account, result: result)
    lastRefresh = Date()
    await syncCapturedCopies(of: capturedCopyCandidates.filter { $0.provider == provider })
    // The fetch may have rotated a Claude token; the email label's retry key
    // is the access-token fingerprint, so this re-fetches exactly once.
    if provider == .claude {
      refreshClaudeProfiles()
    }
  }

  func reloadAccounts() async {
    var next: [UsageProvider: [ProviderAccount]] = [:]
    var refreshedSelections: [(UsageProvider, SelectionUpdate)] = []
    var alreadyCaptured: [String: ProviderAccount] = [:]
    var syncCandidates: [ProviderAccount] = []
    for descriptor in providers {
      synchronizeQuotaNotificationScope(
        account: selectedAccounts[descriptor.id],
        origin: reconciledSelectionOrigins[descriptor.id],
        provider: descriptor.id
      )
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
    refreshClaudeProfiles()
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
    synchronizeQuotaNotificationScope(
      account: account,
      origin: origin,
      provider: provider
    )
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
    enqueueSelectionRefresh(for: provider)
  }
}

extension UsageStore {
  /// Spawns a tracked dashboard refresh. UI and the timer go through this so
  /// `inFlightRefresh` always reflects the actually-running refresh an account
  /// switch may need to await. A second call while one is in flight coalesces
  /// through `refreshRequested` instead of replacing the handle with a task
  /// that would return immediately via the `isRefreshing` guard — otherwise a
  /// switch could await a no-op and race the real refresh's slot write.
  func beginRefresh() {
    // Don't start a fetch while a switch is rewriting a credential slot.
    guard !isSwitching else { return }
    guard inFlightRefresh == nil else {
      refreshRequested = true
      return
    }
    inFlightRefresh = Task { [weak self] in
      await self?.refresh(clearsInFlightRefresh: true)
    }
  }

  func refresh() async {
    await refresh(clearsInFlightRefresh: false)
  }

  private func refresh(clearsInFlightRefresh: Bool) async {
    // Clear the tracked handle before this actor-isolated operation returns.
    // Doing it in the spawning task leaves an executor hop where a new request
    // can observe the completed task, set `refreshRequested`, and be stranded
    // when that task subsequently clears its handle and exits.
    defer {
      if clearsInFlightRefresh {
        inFlightRefresh = nil
      }
    }
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
    // Self-heal email labels after a usage refresh may have rotated a token:
    // the access-token fingerprint changes, so this re-fetches exactly once.
    refreshClaudeProfiles()
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
        beginRefresh()
        await inFlightRefresh?.value
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
