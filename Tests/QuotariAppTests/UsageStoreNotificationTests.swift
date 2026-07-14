import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreNotificationTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func dashboardFetchDeliversOnceForTheLogicalSelectedAccount() async throws {
    let harness = try await makeStore("selected")
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    let live = account(name: "Live", path: "/tmp/live-auth.json")
    let saved = account(name: "Saved", source: .quotariRegistry(id: "codex:saved"))
    store.reconciledSelectionOrigins[.codex] = saved
    let value = fetchResult(accountName: live.displayName)

    store.applySuccessfulFetch(value, provider: .codex, account: live)
    await store.waitForPendingQuotaNotifications()
    store.applySuccessfulFetch(value, provider: .codex, account: live)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    let key = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: saved.id,
      window: .session
    )
    #expect(controller.ledger.windows[key]?.deliveredThresholds == [.warning])
  }

  @Test func selectedAccountsKeepIndependentDeliveryHistory() async throws {
    let harness = try await makeStore("independent")
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    let first = account(name: "First", path: "/tmp/first-auth.json")
    let second = account(name: "Second", path: "/tmp/second-auth.json")

    store.applySuccessfulFetch(fetchResult(accountName: "First"), provider: .codex, account: first)
    store.applySuccessfulFetch(fetchResult(accountName: "Second"), provider: .codex, account: second)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 2)
    #expect(controller.ledger.windows.keys.contains { $0.logicalAccountID == first.id })
    #expect(controller.ledger.windows.keys.contains { $0.logicalAccountID == second.id })
  }

  @Test func mockAndUnattributedAutomaticResultsDoNotNotify() async throws {
    let harness = try await makeStore("unattributed")
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    let snapshot = usage(accountName: nil)

    store.applySuccessfulFetch(
      ProviderFetchResult(usage: snapshot, sourceLabel: "Demo", sourceKind: .mock),
      provider: .codex,
      account: nil
    )
    store.applySuccessfulFetch(
      ProviderFetchResult(usage: snapshot, sourceLabel: "Live", sourceKind: .api),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
    #expect(controller.ledger.windows.isEmpty)
  }

  @Test func automaticResultUsesAConfidentDiscoveredAccountMatch() async throws {
    let discovered = account(name: "Matched", path: "/tmp/matched-auth.json")
    let discovery = StaticAccountDiscovery(accounts: [.codex: [discovered]])
    let harness = try await makeStore(
      "automatic",
      providers: [ProviderRegistry.descriptor(for: .codex)],
      discovery: discovery
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    await store.reloadAccounts()

    store.applySuccessfulFetch(fetchResult(accountName: "Matched"), provider: .codex, account: nil)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(controller.ledger.windows.keys.contains { $0.logicalAccountID == discovered.id })
  }

  @Test func automaticLaunchDiscoversAccountsBeforeFirstNotificationEvaluation() async throws {
    let discovered = account(name: "Matched", path: "/tmp/matched-auth.json")
    let discovery = GatedInitialAccountDiscovery(account: discovered)
    let strategy = GatedNotificationUsageStrategy(snapshot: usage(accountName: "Matched"))
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0, 0),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let harness = try await makeStore(
      "automatic-launch",
      providers: [descriptor],
      discovery: discovery,
      startsAutomatically: true
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center

    await discovery.waitUntilReloadStarts()
    #expect(store.timerTask == nil)

    await discovery.resumeReload()
    await strategy.waitUntilFirstRequestStarts()
    #expect(store.accounts[.codex] == [discovered])
    let firstRefresh = store.inFlightRefresh
    #expect(firstRefresh != nil)

    await strategy.resumeFirstRequest()
    await firstRefresh?.value
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == discovered.id)
    #expect(controller.ledger.windows.keys.allSatisfy { $0.logicalAccountID == discovered.id })

    store.timerTask?.cancel()
    await store.timerTask?.value
  }

  @Test func automaticAndSelectedModesShareTheCapturedLogicalAccount() async throws {
    let live = account(name: "Matched", path: "/tmp/matched-auth.json")
    let saved = account(name: "Saved", source: .quotariRegistry(id: "codex:saved"))
    let discovery = StaticAccountDiscovery(
      accounts: [.codex: [live]],
      capturedCopies: [live.id: saved]
    )
    let harness = try await makeStore(
      "automatic-selected-captured",
      providers: [ProviderRegistry.descriptor(for: .codex)],
      discovery: discovery
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    await store.reloadAccounts()
    let value = fetchResult(accountName: "Matched")

    store.applySuccessfulFetch(value, provider: .codex, account: nil)
    await store.waitForPendingQuotaNotifications()
    store.reconciledSelectionOrigins[.codex] = saved
    store.applySuccessfulFetch(value, provider: .codex, account: live)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(controller.ledger.windows.keys.allSatisfy { $0.logicalAccountID == saved.id })
  }

  @Test func automaticClaudeOAuthResultUsesTheCanonicalLiveCredentialSource() async throws {
    let live = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      credentialIdentity: "live-token"
    )
    let discovery = StaticAccountDiscovery(accounts: [.claude: [live]])
    let harness = try await makeStore(
      "automatic-claude",
      providers: [ProviderRegistry.descriptor(for: .claude)],
      discovery: discovery,
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "live-token") }
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    await store.reloadAccounts()
    let accountID = "automatic-claude-account"
    store.claudeProfiles[live.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "live-token")
    )
    let value = claudeFetchResult(credentialScopeID: live.credentialScopeID)

    store.applySuccessfulFetch(value, provider: .claude, account: nil)
    await store.waitForPendingQuotaNotifications()
    store.applySuccessfulFetch(value, provider: .claude, account: nil)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.map(\.kind) == [.warning, .weeklyReset])
    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)) == [logicalAccountID])
    #expect(controller.ledger.windows.keys.allSatisfy { $0.logicalAccountID == logicalAccountID })
  }

  @Test func accountlessClaudeResultWithoutADiscoveredLiveSourceRemainsUnattributed() async throws {
    let harness = try await makeStore("unattributed-claude")
    let store = harness.store
    let controller = harness.controller
    let center = harness.center

    store.applySuccessfulFetch(claudeFetchResult(), provider: .claude, account: nil)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
    #expect(controller.ledger.windows.isEmpty)
  }

  @Test func accountPopoverRefreshDoesNotDeliverQuotaNotifications() async throws {
    let discovered = account(name: "Popover", path: "/tmp/popover-auth.json")
    let strategy = NotificationUsageStrategy(snapshot: usage(accountName: "Popover"))
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0, 0),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let discovery = StaticAccountDiscovery(accounts: [.codex: [discovered]])
    let harness = try await makeStore(
      "popover",
      providers: [descriptor],
      discovery: discovery
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    await store.reloadAccounts()

    await store.refreshAccountUsage(for: .codex, force: true)

    #expect(center.attemptedRequests.isEmpty)
    #expect(controller.ledger.windows.isEmpty)
  }
}

extension UsageStoreNotificationTests {
  func makeStore(
    _ name: String,
    providers: [ProviderDescriptor] = [],
    discovery: any ProviderAccountDiscovering = StaticAccountDiscovery(),
    codexCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> CodexCredentials? = { _ in nil },
    claudeCredentialLoader: @escaping @Sendable (ProviderCredentialSource) -> ClaudeCredentials? = { _ in nil },
    startsAutomatically: Bool = false
  ) async throws -> UsageNotificationHarness {
    let defaults = try #require(UserDefaults(suiteName: "UsageStoreNotificationTests.\(name)"))
    defaults.removePersistentDomain(forName: "UsageStoreNotificationTests.\(name)")
    let center = UsageNotificationCenterStub()
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let store = UsageStore.isolatedForTesting(
      providers: providers,
      accountDiscovery: discovery,
      codexCredentialLoader: codexCredentialLoader,
      claudeCredentialLoader: claudeCredentialLoader,
      defaults: defaults,
      quotaNotifications: controller,
      startsAutomatically: startsAutomatically
    )
    return UsageNotificationHarness(store: store, controller: controller, center: center)
  }

  func account(
    name: String,
    path: String = "",
    source: ProviderCredentialSource? = nil
  ) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: nil,
      credentialSource: source ?? .codexAuthFile(path: path)
    )
  }

  func usage(accountName: String?) -> UsageSnapshot {
    UsageSnapshot(
      provider: .codex,
      account: accountName,
      primary: RateWindow(
        kind: .session,
        usedPercent: 80,
        resetsAt: now.addingTimeInterval(3600)
      ),
      updatedAt: now
    )
  }

  func fetchResult(accountName: String?) -> ProviderFetchResult {
    ProviderFetchResult(
      usage: usage(accountName: accountName),
      sourceLabel: "Live",
      sourceKind: .api
    )
  }

  func claudeFetchResult(credentialScopeID: String? = nil) -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: .claude,
        primary: RateWindow(
          kind: .session,
          usedPercent: 80,
          resetsAt: now.addingTimeInterval(5 * 3600)
        ),
        secondary: RateWindow(
          kind: .weekly,
          usedPercent: 20,
          resetsAt: now.addingTimeInterval(7 * 24 * 3600)
        ),
        updatedAt: now
      ),
      sourceLabel: "Claude",
      sourceKind: .oauth,
      credentialScopeID: credentialScopeID
    )
  }
}

private struct NotificationUsageStrategy: ProviderFetchStrategy {
  let snapshot: UsageSnapshot
  let id = "notification-usage"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(usage: snapshot, sourceLabel: "Live")
  }
}
