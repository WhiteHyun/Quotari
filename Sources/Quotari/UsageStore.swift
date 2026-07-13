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
  private let profileFetcher: any ClaudeProfileFetching
  private let profileStore: ClaudeProfileStore
  private let claudeCredentialLoader: @Sendable (ProviderCredentialSource) -> ClaudeCredentials?
  private let defaults: UserDefaults
  var captureErrors: [UsageProvider: String] = [:]
  /// Fetched Claude account profiles keyed by `ProviderAccount.id`, used to
  /// label accounts by email. Loaded from disk at launch, refreshed lazily.
  private(set) var claudeProfiles: [String: ClaudeProfile] = [:]
  private var profileFetchTasks: Set<String> = []
  /// The credential fingerprint most recently *attempted* for each account id
  /// (whether it succeeded or not). Keyed so a re-login or token rotation
  /// changes the fingerprint and triggers exactly one fresh attempt, while a
  /// persistent failure for one credential isn't retried on every reload.
  private var profileFetchAttempts: [String: String] = [:]

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
    profileFetcher: any ClaudeProfileFetching = ClaudeProfileFetcher(),
    profileStore: ClaudeProfileStore = ClaudeProfileStore(),
    claudeCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> ClaudeCredentials? = {
      try? ClaudeCredentialsStore.load(source: $0)
    },
    defaults: UserDefaults = .standard,
    startsAutomatically: Bool = true
  ) {
    assert(ProviderRegistry.isComplete, "Every UsageProvider case needs a descriptor")
    self.providers = providers
    self.costEstimator = costEstimator
    self.accountDiscovery = accountDiscovery
    self.accountSelectionStore = accountSelectionStore
    self.accountCapture = accountCapture
    self.profileFetcher = profileFetcher
    self.profileStore = profileStore
    self.claudeCredentialLoader = claudeCredentialLoader
    self.defaults = defaults
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
    // Self-heal email labels after a usage refresh may have rotated a token:
    // the access-token fingerprint changes, so this re-fetches exactly once.
    refreshClaudeProfiles()
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

// MARK: - Claude account email labels

extension UsageStore {
  /// The label to show for an account: a fetched Claude email when available,
  /// otherwise the discovered display name.
  func accountLabel(for account: ProviderAccount) -> String {
    if account.provider == .claude, let email = claudeProfiles[account.id]?.email, !email.isEmpty {
      return email
    }
    return account.displayName
  }

  func organizationName(for account: ProviderAccount) -> String? {
    claudeProfiles[account.id]?.organizationName
  }

  /// Resolves email labels for Claude accounts. The retry key is a fingerprint
  /// of the *access token* (not the durable identity), so any token rotation —
  /// including an access-token-only refresh — triggers exactly one fresh
  /// fetch, and a stuck credential is retried the moment its token changes.
  /// A cached profile whose fingerprint no longer matches the live credential
  /// is dropped once a confirming fetch proves the credential bad, so a reused
  /// credential slot never keeps showing the previous account's email.
  func refreshClaudeProfiles() {
    for account in accounts[.claude] ?? [] where !profileFetchTasks.contains(account.id) {
      let id = account.id
      let source = account.credentialSource
      profileFetchTasks.insert(id)
      Task {
        defer { profileFetchTasks.remove(id) }
        await resolveClaudeProfile(id: id, source: source)
      }
    }
  }

  /// One account's profile-resolution loop, run under a per-account in-flight
  /// guard. It re-reads the credential after each fetch: because the guard
  /// blocks a concurrent generation from starting, the credential can rotate
  /// *during* a fetch — so once a fetch finishes we check whether the live
  /// token changed and fetch again if so, instead of leaving a stale write
  /// with nothing queued. Bounded so a pathological rotation can't spin.
  private func resolveClaudeProfile(id: String, source: ProviderCredentialSource) async {
    let fetcher = profileFetcher
    let loader = claudeCredentialLoader
    for _ in 0 ..< 5 {
      guard let credential = await Task.detached(operation: { () -> Credential? in
        guard let credentials = loader(source) else { return nil }
        return Credential(
          fingerprint: ProviderCredentialIdentity.fingerprint(of: credentials.accessToken),
          token: credentials.accessToken
        )
      }).value else { return }
      // The current token was already attempted (success or auth failure) —
      // nothing more to do until it changes.
      guard profileFetchAttempts[id] != credential.fingerprint else { return }
      // Claude's payload has no durable pre-fetch account id (both tokens
      // rotate), so we can't tell "different account" from "same account, new
      // token" before fetching. The cached email therefore stays visible until
      // a fetch confirms otherwise: an access-token rotation is usually the
      // same account (no flicker), and a genuinely different account is dropped
      // once its fetch returns empty or 401. (A reused slot seen only while
      // offline keeps the prior email until connectivity returns — an accepted
      // tradeoff, since flickering on every routine token rotation is worse.)
      let cachedIsForOldToken = claudeProfiles[id].map { $0.fingerprint != credential.fingerprint } ?? false
      profileFetchAttempts[id] = credential.fingerprint
      do {
        let profile = try await fetcher.fetchProfile(accessToken: credential.token)
        if profile.isEmpty {
          dropStaleProfile(id: id, cachedIsForOldToken: cachedIsForOldToken)
        } else {
          claudeProfiles[id] = ClaudeProfile(
            email: profile.email,
            organizationName: profile.organizationName,
            fingerprint: credential.fingerprint
          )
          try? profileStore.save(claudeProfiles)
        }
      } catch ProviderHTTPError.unauthorized {
        // The token is denied. If it's a token we hadn't fetched with before,
        // the cached email may belong to a now-replaced account, so drop it.
        dropStaleProfile(id: id, cachedIsForOldToken: cachedIsForOldToken)
        // Don't break: a usage refresh may have rotated and persisted a new
        // token during this 401, so loop to re-read the source. If the token
        // is unchanged, the already-attempted guard above returns next pass.
      } catch {
        // Transient (network / 5xx): keep any cache, clear the marker so the
        // next cycle retries with the same token, and stop looping.
        if profileFetchAttempts[id] == credential.fingerprint {
          profileFetchAttempts[id] = nil
        }
        return
      }
    }
  }

  private func dropStaleProfile(id: String, cachedIsForOldToken: Bool) {
    guard cachedIsForOldToken, claudeProfiles[id] != nil else { return }
    claudeProfiles[id] = nil
    try? profileStore.save(claudeProfiles)
  }

  private struct Credential: Sendable {
    var fingerprint: String
    var token: String
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
