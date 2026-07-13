import Foundation
@testable import Quotari
@testable import QuotariCore

/// Discovery stub: returns exactly the accounts a test provides, never the
/// credentials of the machine running the tests.
struct StaticAccountDiscovery: ProviderAccountDiscovering {
  var accounts: [UsageProvider: [ProviderAccount]] = [:]
  /// Saved-account id → the live account hiding it, mirroring the production
  /// discovery's identity-equivalence lookup.
  var liveEquivalents: [String: ProviderAccount] = [:]
  /// The hidden saved copy behind each live account id.
  var capturedCopies: [String: ProviderAccount] = [:]

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    accounts[provider] ?? []
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    liveEquivalents[account.id]
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    capturedCopies.filter { id, _ in accounts.contains { $0.id == id } }
  }
}

/// Discovery stub whose results a test can swap between reloads (e.g. the
/// CLI slot being reused by another login mid-session).
final class MutableAccountDiscovery: ProviderAccountDiscovering, @unchecked Sendable {
  private let lock = NSLock()
  private var current: StaticAccountDiscovery

  init(_ initial: StaticAccountDiscovery) {
    current = initial
  }

  func update(_ discovery: StaticAccountDiscovery) {
    lock.withLock { current = discovery }
  }

  private var snapshot: StaticAccountDiscovery {
    lock.withLock { current }
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    await snapshot.accounts(for: provider)
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    await snapshot.liveAccount(equivalentTo: account, among: accounts)
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    await snapshot.capturedCopies(among: accounts)
  }
}

/// Cost estimator stub for tests that don't exercise cost scanning; the
/// production default (`LocalUsageCostEstimator`) would scan real usage logs.
struct NullCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}

/// Profile fetcher stub so tests never hit the real `/api/oauth/profile`
/// endpoint (the production default `ClaudeProfileFetcher` would).
struct NullProfileFetcher: ClaudeProfileFetching {
  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    ClaudeProfile()
  }
}

extension ClaudeProfileStore {
  /// A profile cache backed by a throwaway temp file, so tests neither read
  /// nor overwrite the user's real Application Support profiles.
  static func temporaryForTesting() -> ClaudeProfileStore {
    ClaudeProfileStore(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent("quotari-profiles-\(UUID().uuidString).json")
    )
  }
}

extension AccountCaptureService {
  /// A capture service backed by an in-memory keychain, so tests never touch
  /// the real keychain when a store constructs its default.
  static func inMemoryForTesting(capturedAccounts: CapturedAccountStore? = nil) -> AccountCaptureService {
    AccountCaptureService(
      capturedAccounts: capturedAccounts ?? .inMemoryForTesting(),
      claudeKeychainRead: { _ in nil }
    )
  }
}

extension CapturedAccountStore {
  /// A registry backed by an in-memory keychain, so tests can inspect what
  /// a capture service persisted without touching the real keychain.
  static func inMemoryForTesting() -> CapturedAccountStore {
    let box = InMemoryKeychainBox()
    let keychain = KeychainItemStore(
      read: { box.read($0) },
      write: { box.write($0, $1) },
      delete: { box.delete($0) }
    )
    return CapturedAccountStore(keychain: keychain, service: "Test-\(UUID().uuidString)")
  }
}

extension AccountSwitchService {
  /// A switch service that can never reach the real machine: in-memory
  /// registry, empty environment, throwaway home, and a keychain that reads
  /// nothing and refuses writes.
  static func isolatedForTesting(
    capturedAccounts: CapturedAccountStore = .inMemoryForTesting(),
    environment: [String: String] = [:],
    home: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-switch-\(UUID().uuidString)"),
    keychainRead: (@Sendable (String) -> Data?)? = nil,
    keychainWrite: (@Sendable (Data, String) throws -> Void)? = nil
  ) -> AccountSwitchService {
    AccountSwitchService(
      capturedAccounts: capturedAccounts,
      capture: .inMemoryForTesting(capturedAccounts: capturedAccounts),
      environment: environment,
      home: home,
      keychainRead: keychainRead ?? { _ in nil },
      keychainWrite: keychainWrite ?? { _, _ in throw KeychainItemStore.KeychainError.commandFailed(status: 1) }
    )
  }
}

private final class InMemoryKeychainBox: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]
  func read(_ s: String) -> Data? {
    lock.withLock { items[s] }
  }

  func write(_ d: Data, _ s: String) {
    lock.withLock { items[s] = d }
  }

  func delete(_ s: String) {
    lock.withLock { items[s] = nil }
  }
}

extension ProviderAccountSelectionStore {
  /// A selection store backed by a fresh temp file, so tests neither read nor
  /// overwrite the user's real `Application Support/Quotari` selection.
  static func temporaryForTesting() -> ProviderAccountSelectionStore {
    ProviderAccountSelectionStore(
      url: FileManager.default.temporaryDirectory
        .appendingPathComponent("quotari-tests-\(UUID().uuidString).json")
    )
  }
}

extension UsageStore {
  /// The only way tests should construct a `UsageStore`: every dependency the
  /// production initializer defaults to something that reads the running
  /// machine (credential discovery, the account-selection file, UserDefaults,
  /// local usage logs) is replaced with an isolated stand-in. PS-142 traced a
  /// CI flake to a test picking up the machine's real Codex credentials
  /// through `reloadAccounts()`; routing construction through this helper is
  /// what keeps that class of flake out.
  static func isolatedForTesting(
    providers: [ProviderDescriptor],
    costEstimator: any UsageCostEstimating = NullCostEstimator(),
    accountDiscovery: any ProviderAccountDiscovering = StaticAccountDiscovery(),
    accountSelectionStore: ProviderAccountSelectionStore = .temporaryForTesting(),
    accountCapture: AccountCaptureService = .inMemoryForTesting(),
    accountSwitch: AccountSwitchService? = nil,
    profileFetcher: any ClaudeProfileFetching = NullProfileFetcher(),
    profileStore: ClaudeProfileStore = .temporaryForTesting(),
    claudeCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> ClaudeCredentials? = { _ in nil },
    defaults: UserDefaults? = nil,
    quotaNotifications: QuotaNotificationController? = nil,
    startsAutomatically: Bool = true
  ) -> UsageStore {
    let isolatedDefaults = defaults ?? ephemeralDefaults()
    let isolatedNotifications = quotaNotifications ?? QuotaNotificationController(
      center: UnavailableQuotaNotificationCenter(),
      defaults: isolatedDefaults
    )
    return UsageStore(
      providers: providers,
      costEstimator: costEstimator,
      accountDiscovery: accountDiscovery,
      accountSelectionStore: accountSelectionStore,
      accountCapture: accountCapture,
      accountSwitch: accountSwitch ?? .isolatedForTesting(),
      profileFetcher: profileFetcher,
      profileStore: profileStore,
      claudeCredentialLoader: claudeCredentialLoader,
      defaults: isolatedDefaults,
      quotaNotifications: isolatedNotifications,
      startsAutomatically: startsAutomatically
    )
  }

  /// Falling back to `.standard` here would silently restore the machine-state
  /// dependency this helper exists to remove, so fail loudly instead.
  private static func ephemeralDefaults() -> UserDefaults {
    let suiteName = "quotari-tests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Could not create isolated UserDefaults suite \(suiteName)")
    }
    return defaults
  }
}

@MainActor
private final class UnavailableQuotaNotificationCenter: QuotaNotificationCenterTransport {
  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    .denied
  }

  func requestAuthorization() async throws -> Bool {
    false
  }

  func pendingScheduledRequestIdentifiers() async -> Set<String> {
    []
  }

  func add(_ request: QuotaNotificationRequest) async throws {}

  func removePendingRequests(withIdentifiers identifiers: [String]) {}

  func removeRequests(withIdentifiers identifiers: [String]) {}

  func configureForegroundPresentation() {}
}

struct EmptyCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}

actor AccountRecorder {
  private(set) var accounts: [ProviderAccount?] = []

  func record(_ account: ProviderAccount?) {
    accounts.append(account)
  }
}

struct RecordingAccountStrategy: ProviderFetchStrategy {
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

actor AccountSwitchRaceStrategy: ProviderFetchStrategy {
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

final class TemporaryDirectory {
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
