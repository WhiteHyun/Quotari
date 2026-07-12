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

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    accounts[provider] ?? []
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    liveEquivalents[account.id]
  }
}

/// Cost estimator stub for tests that don't exercise cost scanning; the
/// production default (`LocalUsageCostEstimator`) would scan real usage logs.
struct NullCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
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
    defaults: UserDefaults? = nil,
    startsAutomatically: Bool = true
  ) -> UsageStore {
    UsageStore(
      providers: providers,
      costEstimator: costEstimator,
      accountDiscovery: accountDiscovery,
      accountSelectionStore: accountSelectionStore,
      defaults: defaults ?? ephemeralDefaults(),
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
