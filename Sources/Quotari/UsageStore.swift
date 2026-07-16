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
  private(set) var providersWithDiscoveredCredentials = Set<UsageProvider>()
  private(set) var credentialDiscoveryCompleted = Set<UsageProvider>()
  private(set) var selectedAccounts: [UsageProvider: ProviderAccount] = [:]
  /// The live account each CLI resolves without an explicit Quotari override.
  /// This is discovered from provider configuration rather than row order.
  private(set) var activeCLIAccounts: [UsageProvider: ProviderAccount] = [:]
  /// Visible accounts whose quota and usage are refreshed in the background.
  /// This is independent from the single account shown on the dashboard.
  var monitoredAccounts: [UsageProvider: [ProviderAccount]] = [:]
  /// Logical persisted monitoring choices. A live CLI row is stored as its
  /// managed registry account so a mutable credential slot cannot transfer
  /// monitoring to a different login after an external switch.
  var persistedMonitoredAccounts: [UsageProvider: [ProviderAccount]] = [:]
  /// False when the persisted monitoring file could not be read. In that
  /// state monitoring fails closed and no partial in-memory view may replace
  /// the user's last durable choices.
  var isMonitoringConfigurationLoaded = true
  /// The hidden saved registry copy behind each live account, keyed by the
  /// live account's id — identities that are saved while also being live.
  private(set) var capturedEquivalents: [String: ProviderAccount] = [:]
  /// The saved account a reconciled live selection stands in for; kept so the
  /// persisted selection stays on the saved account and a later slot reuse
  /// falls back to it instead of silently following the slot.
  var reconciledSelectionOrigins: [UsageProvider: ProviderAccount] = [:]
  var accountUsage: [UsageProvider: [String: ProviderAccountUsage]] = [:]
  var refreshingAccountUsageProviders = Set<UsageProvider>()
  var isRefreshing = false
  // Settable from the refresh extension (a sibling file) that records it.
  var lastRefresh: Date?
  /// The most recent spawned dashboard refresh, so a credential-slot mutation
  /// (an account switch) can await any in-flight refresh — which can rotate
  /// and persist a live token — before reading and overwriting the slot.
  var inFlightRefresh: Task<Void, Never>?
  /// The shared account-discovery pass used by app activation, Settings, and
  /// manual reloads. Joining this task prevents simultaneous lifecycle events
  /// from repeating the same keychain and credential-file reads.
  private(set) var inFlightAccountReload: Task<Void, Never>?
  /// Providers whose discovered credentials are being copied into the registry.
  /// A fetch that starts after this gate closes waits for the reload to finish,
  /// so it receives the newly established live-to-registry identity link.
  var automaticallyCapturingProviders = Set<UsageProvider>()
  private(set) var accountRediscoveryRequest: UInt = 0
  private(set) var completedAccountRediscoveryRequest: UInt = 0
  /// Add Account requests that must preserve a live CLI credential even when
  /// its provider is disabled. The request generation keeps this override on
  /// the exact coalesced reload that the caller awaits.
  var accountPreservationRequests: [UsageProvider: UInt] = [:]
  private var accountRediscoveryWaiters: [AccountRediscoveryWaiter] = []
  /// True while an account switch is writing a credential slot. Refreshes are
  /// suppressed for the window so none rotates/persists a slot the switch is
  /// mid-way through reading and overwriting. This coordinates Quotari's own
  /// work only; the switch service separately checks for active CLI processes
  /// and the user must still avoid launching one during the switch.
  /// Set by the switch flow (in a sibling extension), so not `private(set)`.
  var isSwitching = false
  var addingAccountProviders = Set<UsageProvider>()
  var accountLoginTasks: [UsageProvider: Task<Void, Never>] = [:]
  var accountLoginPhases: [UsageProvider: AccountLoginPhase] = [:]
  var accountLoginErrors: [UsageProvider: String] = [:]
  var accountLoginOutputs: [UsageProvider: String] = [:]
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
  let accountMonitoringStore: ProviderAccountMonitoringStore
  let accountCapture: AccountCaptureService
  let accountLogin: AccountLoginService
  let automaticallyCapturesDiscoveredAccounts: Bool
  let accountSwitch: AccountSwitchService
  let profileFetcher: any ClaudeProfileFetching
  let profileStore: ClaudeProfileStore
  let providerActivation: ProviderActivationController
  let menuBarPreferences: MenuBarPreferencesController
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

  var timerTask: Task<Void, Never>?
  var refreshRequested = false
  var accountRevisions: [UsageProvider: UInt] = [:]
  var costTasks: [UsageProvider: CostRefreshTask] = [:]
  var lastCostScans: [UsageProvider: Date] = [:]
  var lastEmptyCostScans: [UsageProvider: Date] = [:]
  var latestReportedCostFallbacks: [UsageProvider: ReportedCostFallback] = [:]
  var accountUsageRefreshTasks: [UsageProvider: AccountUsageRefreshTask] = [:]
  var providerFetchTasks: [UsageProvider: ProviderFetchTask] = [:]
  var selectionProviderFetchTasks: [UsageProvider: ProviderFetchTask] = [:]
  /// Credential transitions completed by Quotari immediately before an
  /// account scan. Fetch handles disappear at completion, but rediscovery
  /// still needs this evidence to distinguish a token rotation from an
  /// external login replacing the same mutable CLI slot.
  var completedCredentialTransitions: [UsageProvider: [String: Set<String>]] = [:]
  /// The fetch `selectAccount` starts, tracked so an account switch can await
  /// it (it may rotate/persist the live token the switch is about to back up).
  var selectionRefreshTasks: [UsageProvider: Task<Void, Never>] = [:]
  /// Disabling clears per-account usage. The first successful provider fetch
  /// after reactivation consumes this marker and restores every monitored row.
  var providersNeedingMonitoredUsageRestore = Set<UsageProvider>()
  /// User-selection refreshes block a dashboard generation that has not yet
  /// entered its provider fetch. Reactivation refreshes are excluded because
  /// they may already be waiting for that same dashboard generation to drain.
  /// The latest user-selection generation a dashboard must drain before it
  /// snapshots this provider's account. Provider reactivation is deliberately
  /// excluded because it may already be waiting for that dashboard.
  var dashboardBlockingSelectionRefreshes: [UsageProvider: UUID] = [:]
  var quotaNotificationTask: Task<Void, Never>?
  var deferredClaudeQuotaNotifications: [String: DeferredClaudeQuotaNotification] = [:]
  var notificationScopeIDsByAccountID: [String: String] = [:]
  var scopedNotificationAccountIDs: [UsageProvider: Set<String>] = [:]

  /// Tests inject mock descriptors so results don't depend on credentials
  /// present on the machine running them.
  init(
    providers: [ProviderDescriptor] = ProviderRegistry.all,
    costEstimator: any UsageCostEstimating = LocalUsageCostEstimator(),
    accountDiscovery: any ProviderAccountDiscovering = ProviderAccountDiscovery(),
    accountSelectionStore: ProviderAccountSelectionStore = ProviderAccountSelectionStore(),
    accountMonitoringStore: ProviderAccountMonitoringStore? = nil,
    accountCapture: AccountCaptureService = AccountCaptureService(),
    accountLogin: AccountLoginService = AccountLoginService(),
    automaticallyCapturesDiscoveredAccounts: Bool = true,
    accountSwitch: AccountSwitchService? = nil,
    profileFetcher: any ClaudeProfileFetching = ClaudeProfileFetcher(),
    profileStore: ClaudeProfileStore = ClaudeProfileStore(),
    codexCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> CodexCredentials? = {
      try? CodexCredentialsStore.load(source: $0)
    },
    claudeCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> ClaudeCredentials? = {
      try? ClaudeCredentialsStore.load(source: $0)
    },
    defaults: UserDefaults = .standard,
    providerActivation: ProviderActivationController? = nil,
    menuBarPreferences: MenuBarPreferencesController? = nil,
    quotaNotifications: QuotaNotificationController? = nil,
    startsAutomatically: Bool = true
  ) {
    assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
    self.providers = providers
    self.costEstimator = costEstimator
    self.accountDiscovery = accountDiscovery
    self.accountSelectionStore = accountSelectionStore
    self.accountMonitoringStore = accountMonitoringStore ?? ProviderAccountMonitoringStore(
      url: accountSelectionStore.url
        .deletingLastPathComponent()
        .appendingPathComponent("MonitoredProviderAccounts.json")
    )
    self.accountCapture = accountCapture
    self.accountLogin = accountLogin
    self.automaticallyCapturesDiscoveredAccounts = automaticallyCapturesDiscoveredAccounts
    self.accountSwitch = accountSwitch ?? AccountSwitchService(
      activeCLIProcesses: CLIActivityDetector().activeProcesses
    )
    self.profileFetcher = profileFetcher
    self.profileStore = profileStore
    self.codexCredentialLoader = codexCredentialLoader
    self.claudeCredentialLoader = claudeCredentialLoader
    self.defaults = defaults
    self.providerActivation = providerActivation ?? ProviderActivationController(defaults: defaults)
    self.menuBarPreferences = menuBarPreferences ?? MenuBarPreferencesController(defaults: defaults)
    self.quotaNotifications = quotaNotifications ?? QuotaNotificationController(defaults: defaults)
    selectedAccounts = accountSelectionStore.load()
    do {
      persistedMonitoredAccounts = try self.accountMonitoringStore.load()
    } catch {
      // Explicit empty arrays prevent a read failure from being mistaken for
      // first launch and turning monitoring back on for every discovered row.
      persistedMonitoredAccounts = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, []) })
      isMonitoringConfigurationLoaded = false
    }
    claudeProfiles = profileStore.load()
    // refreshInterval has no inline default: its first assignment runs the
    // @Observable-generated init accessor instead of the setter, so restoring
    // here neither rewrites defaults nor starts the timer via didSet.
    let savedInterval = defaults.double(forKey: Self.refreshIntervalDefaultsKey)
    let range = Self.refreshIntervalRange
    refreshInterval = savedInterval > 0
      ? min(max(savedInterval, range.lowerBound), range.upperBound)
      : 60
    reconcileMenuBarUsageSource()
    // Seed attempts from the cache so a stable account isn't re-fetched on
    // every launch — only when its credential fingerprint changes.
    profileFetchAttempts = claudeProfiles.compactMapValues(\.fingerprint)
    if startsAutomatically {
      Task {
        _ = await self.quotaNotifications.refreshAuthorizationStatus()
        await reloadAccounts()
        startTimer(reusesLatestAccountReloadForFirstRefresh: true)
      }
    }
  }
}

extension UsageStore {
  func beginAccountRediscovery() {
    accountRediscoveryRequest &+= 1
    startQueuedAccountRediscoveryIfNeeded()
  }

  func startQueuedAccountRediscoveryIfNeeded(allowWhileSwitching: Bool = false) {
    guard allowWhileSwitching || !isSwitching,
          inFlightAccountReload == nil,
          completedAccountRediscoveryRequest != accountRediscoveryRequest
    else { return }
    let drainableRequest = accountRediscoveryRequest
    inFlightAccountReload = Task { [weak self] in
      await self?.performQueuedAccountRediscovery(startingWith: drainableRequest)
    }
  }

  func reloadAccounts(preserving provider: UsageProvider? = nil) async {
    accountRediscoveryRequest &+= 1
    let request = accountRediscoveryRequest
    if let provider {
      accountPreservationRequests[provider] = request
    }
    startQueuedAccountRediscoveryIfNeeded()
    await waitForAccountRediscovery(request)
  }

  func reloadAccountsDuringSwitch() async {
    accountRediscoveryRequest &+= 1
    let request = accountRediscoveryRequest
    startQueuedAccountRediscoveryIfNeeded(allowWhileSwitching: true)
    await waitForAccountRediscovery(request)
  }

  private func performQueuedAccountRediscovery(startingWith drainableRequest: UInt) async {
    defer {
      inFlightAccountReload = nil
      startQueuedAccountRediscoveryIfNeeded()
    }
    var request = isSwitching ? drainableRequest : accountRediscoveryRequest
    while completedAccountRediscoveryRequest != request {
      let preservingProviders = accountPreservationProviders(through: request)
      await performAccountReload(preserving: preservingProviders)
      completeAccountPreservationRequests(preservingProviders, through: request)
      completedAccountRediscoveryRequest = request
      resumeAccountRediscoveryWaiters(through: request)
      // Once a switch closes the gate, finish only the pass that was already
      // reading. Its newer requests stay queued for the mandatory post-write
      // discovery (or for the reopened gate after that pass).
      guard !isSwitching else { return }
      request = accountRediscoveryRequest
    }
  }

  private func waitForAccountRediscovery(_ request: UInt) async {
    guard completedAccountRediscoveryRequest < request else { return }
    await withCheckedContinuation { continuation in
      accountRediscoveryWaiters.append(.init(request: request, continuation: continuation))
    }
  }

  private func resumeAccountRediscoveryWaiters(through request: UInt) {
    var pending: [AccountRediscoveryWaiter] = []
    for waiter in accountRediscoveryWaiters {
      if waiter.request <= request {
        waiter.continuation.resume()
      } else {
        pending.append(waiter)
      }
    }
    accountRediscoveryWaiters = pending
  }

  private func performAccountReload(preserving providersForLogin: Set<UsageProvider>) async {
    var gatedProviders = Set<UsageProvider>()
    defer { automaticallyCapturingProviders.subtract(gatedProviders) }
    var reloadStates: [UsageProvider: ProviderAccountReloadState] = [:]
    var nextProvidersWithDiscoveredCredentials = Set<UsageProvider>()
    var refreshedSelections: [(UsageProvider, SelectionUpdate)] = []
    var nextActiveCLIAccounts: [UsageProvider: ProviderAccount] = [:]
    var alreadyCaptured: [String: ProviderAccount] = [:]
    var syncCandidates: [ProviderAccount] = []
    for descriptor in providers {
      let state = await reloadProviderState(for: descriptor, preserving: providersForLogin)
      if state.keepsCaptureGate {
        gatedProviders.insert(state.provider)
      }
      if !state.accounts.isEmpty {
        nextProvidersWithDiscoveredCredentials.insert(state.provider)
      }
      if let selectionUpdate = state.selectionUpdate {
        refreshedSelections.append((state.provider, selectionUpdate))
      }
      if let activeCLIAccount = state.activeCLIAccount {
        nextActiveCLIAccounts[state.provider] = activeCLIAccount
      }
      alreadyCaptured.merge(state.capturedCopies) { current, _ in current }
      syncCandidates += state.accounts.filter { state.capturedCopies.keys.contains($0.id) }
      reloadStates[state.provider] = state
    }
    // Reconcile monitoring only after every provider await has completed. A
    // Settings toggle can run while this main-actor reload is suspended; using
    // the latest persisted choices here prevents an earlier provider snapshot
    // from overwriting that user action when a later provider finishes.
    let persistedMonitoringBeforeReconciliation = persistedMonitoredAccounts
    var nextMonitoredAccounts: [UsageProvider: [ProviderAccount]] = [:]
    for descriptor in providers {
      nextMonitoredAccounts[descriptor.id] = reloadedMonitoredAccounts(
        reloadStates[descriptor.id],
        capturedCopies: alreadyCaptured
      )
    }
    accounts = reloadStates.mapValues(\.accounts)
    providersWithDiscoveredCredentials = nextProvidersWithDiscoveredCredentials
    credentialDiscoveryCompleted = Set(providers.map(\.id))
    capturedEquivalents = alreadyCaptured
    activeCLIAccounts = nextActiveCLIAccounts
    monitoredAccounts = nextMonitoredAccounts
    for (provider, update) in refreshedSelections {
      selectAccount(update.account, for: provider, standingInFor: update.origin)
    }
    if persistedMonitoredAccounts != persistedMonitoringBeforeReconciliation {
      persistMonitoringSelections()
    }
    await finishAccountReload(syncCandidates: syncCandidates)
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
    cancelCostRefresh(for: provider)
    lastCostScans[provider] = nil
    lastEmptyCostScans[provider] = nil
    latestReportedCostFallbacks[provider] = nil
    enqueueSelectionRefresh(for: provider)
  }
}

private struct AccountRediscoveryWaiter {
  let request: UInt
  let continuation: CheckedContinuation<Void, Never>
}
