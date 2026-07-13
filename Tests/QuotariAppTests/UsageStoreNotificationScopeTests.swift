import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension UsageStoreNotificationTests {
  @Test func selectedLiveStandInUsesSavedScopeAndSwitchingAccountsClearsItsReset() async throws {
    let harness = try await makeStore("selected-scope-cleanup")
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    let live = account(name: "Live", path: "/tmp/live-auth.json")
    let saved = account(name: "Saved", source: .quotariRegistry(id: "codex:saved"))
    let replacement = account(name: "Replacement", path: "/tmp/replacement-auth.json")
    store.selectAccount(live, for: .codex, standingInFor: saved)
    await store.selectionRefreshTasks[.codex]?.value

    store.applySuccessfulFetch(
      weeklyFetchResult(accountName: live.displayName),
      provider: .codex,
      account: live
    )
    await store.waitForPendingQuotaNotifications()
    let reset = try #require(center.attemptedRequests.first)
    #expect(reset.key.logicalAccountID == saved.id)
    #expect(center.pendingIDs == [reset.requestID])

    store.selectAccount(replacement, for: .codex)

    #expect(center.pendingIDs.isEmpty)
    #expect(controller.ledger.windows[reset.key]?.scheduledReset == nil)
  }

  @Test func initialAutomaticScopeClearsOldResetThenAttributedSnapshotReschedulesIt() async throws {
    let discovered = account(name: "Matched", path: "/tmp/matched-auth.json")
    let discovery = StaticAccountDiscovery(accounts: [.codex: [discovered]])
    let descriptor = emptyDescriptor(for: .codex)
    let harness = try await makeStore(
      "initial-automatic-scope",
      providers: [descriptor],
      discovery: discovery
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    let old = await controller.process(
      snapshot: weeklyUsage(accountName: discovered.displayName),
      logicalAccountID: discovered.id,
      sourceKind: .api,
      now: now
    )
    let resetID = try #require(old.acceptedRequestIDs.first)
    #expect(center.pendingIDs == [resetID])

    await store.reloadAccounts()

    #expect(center.pendingIDs.isEmpty)
    #expect(controller.ledger.windows.values.allSatisfy { $0.scheduledReset == nil })

    store.applySuccessfulFetch(
      weeklyFetchResult(accountName: discovered.displayName),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.pendingIDs == [resetID])
    #expect(center.attemptedRequests.count == 2)
    #expect(center.attemptedRequests.last?.key.logicalAccountID == discovered.id)
  }

  @Test func unattributedAutomaticResultClearsThePreviousAccountsReset() async throws {
    let discovered = account(name: "Matched", path: "/tmp/matched-auth.json")
    let discovery = StaticAccountDiscovery(accounts: [.codex: [discovered]])
    let harness = try await makeStore(
      "unattributed-automatic-scope",
      providers: [emptyDescriptor(for: .codex)],
      discovery: discovery
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    await store.reloadAccounts()

    store.applySuccessfulFetch(
      weeklyFetchResult(accountName: discovered.displayName),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()
    let reset = try #require(center.attemptedRequests.first)
    #expect(center.pendingIDs == [reset.requestID])

    store.applySuccessfulFetch(
      weeklyFetchResult(accountName: "Different login"),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.pendingIDs.isEmpty)
    #expect(controller.ledger.windows[reset.key]?.scheduledReset == nil)
  }

  @Test func automaticCodexSlotReuseRefreshesIdentityBeforeAttribution() async throws {
    let path = "/tmp/reused-auth.json"
    let first = ProviderAccount(
      provider: .codex,
      displayName: "First login",
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: "acct-first"
    )
    let second = ProviderAccount(
      provider: .codex,
      displayName: "Second login",
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: "acct-second"
    )
    let discovery = MutableAccountDiscovery(
      StaticAccountDiscovery(accounts: [.codex: [first]])
    )
    let harness = try await makeStore(
      "reused-live-slot",
      providers: [emptyDescriptor(for: .codex)],
      discovery: discovery
    )
    let store = harness.store
    let center = harness.center
    await store.reloadAccounts()

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth
      ),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()
    #expect(center.attemptedRequests.count == 1)

    discovery.update(StaticAccountDiscovery(accounts: [.codex: [second]]))
    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth
      ),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 2)
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)).count == 2)
  }

  @Test func claudeAccessTokenRotationPreservesNotificationHistory() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let beforeRotation = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: "Keychain",
      credentialSource: source,
      credentialIdentity: "access-token-before"
    )
    let afterRotation = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: "Keychain",
      credentialSource: source,
      credentialIdentity: "access-token-after"
    )
    let harness = try await makeStore("claude-token-rotation")
    let store = harness.store
    let center = harness.center

    store.applySuccessfulFetch(
      claudeFetchResult(),
      provider: .claude,
      account: beforeRotation
    )
    await store.waitForPendingQuotaNotifications()
    store.applySuccessfulFetch(
      claudeFetchResult(),
      provider: .claude,
      account: afterRotation
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.map(\.kind) == [.warning, .weeklyReset])
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)) == [beforeRotation.id])
  }

  @Test func accountlessAutomaticCodexOAuthUsesItsOnlyDiscoveredLiveSlot() async throws {
    let live = ProviderAccount(
      provider: .codex,
      displayName: "Codex account",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/account-id-only-auth.json"),
      credentialIdentity: "acct-id-only"
    )
    let harness = try await makeStore(
      "accountless-codex-oauth",
      providers: [emptyDescriptor(for: .codex)],
      discovery: StaticAccountDiscovery(accounts: [.codex: [live]])
    )
    let store = harness.store
    let center = harness.center
    await store.reloadAccounts()

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth
      ),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
  }

  func weeklyFetchResult(accountName: String?) -> ProviderFetchResult {
    ProviderFetchResult(
      usage: weeklyUsage(accountName: accountName),
      sourceLabel: "Live",
      sourceKind: .api
    )
  }

  func weeklyUsage(accountName: String?) -> UsageSnapshot {
    UsageSnapshot(
      provider: .codex,
      account: accountName,
      secondary: RateWindow(
        kind: .weekly,
        usedPercent: 20,
        resetsAt: now.addingTimeInterval(7 * 24 * 3600)
      ),
      updatedAt: now
    )
  }

  func emptyDescriptor(for provider: UsageProvider) -> ProviderDescriptor {
    ProviderDescriptor(
      id: provider,
      metadata: ProviderMetadata(
        displayName: provider.rawValue,
        accent: .init(0, 0, 0),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
  }
}
