import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MonitoringScopeEdgeCaseTests {
  @Test func pruningOldDeferredClaudeAlertsRestoresMonitoredScope() async throws {
    let token = "deferred-scope-token"
    let account = claudeAccount(token: token)
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore(
      "pruned-deferred-restores-scope",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token) }
    )
    let store = harness.store
    store.monitoredAccounts[.claude] = [account]
    store.claudeProfiles[account.id] = verifiedProfile(id: "deferred-account", token: token)
    store.accountRevisions[.claude] = 1
    store.deferredClaudeQuotaNotifications[account.id] = DeferredClaudeQuotaNotification(
      snapshot: support.claudeFetchResult(credentialScopeID: account.credentialScopeID).usage,
      account: account,
      sourceKind: .oauth,
      credentialScopeID: account.credentialScopeID,
      revision: 0,
      updatesNotificationScope: false
    )
    harness.controller.setActiveLogicalAccountIDs([], for: .claude)

    store.enqueueClaudeQuotaNotificationScopeRestore()
    await store.waitForPendingQuotaNotifications()

    let scopeID = try #require(store.notificationScopeID(for: account))
    #expect(store.deferredClaudeQuotaNotifications.isEmpty)
    #expect(harness.controller.activeLogicalAccountIDs[.claude] == [scopeID])
  }

  @Test func staleLiveAliasKeepsItsMonitoredCapturedReset() async throws {
    let support = UsageStoreNotificationTests()
    let live = codexAccount(identity: "old-account")
    let replacement = codexAccount(identity: "new-account")
    let saved = support.account(name: "Saved", source: .quotariRegistry(id: "captured-alias"))
    let harness = try await support.makeStore(
      "stale-captured-alias-keeps-reset",
      providers: [ProviderRegistry.descriptor(for: .codex)],
      discovery: StaticAccountDiscovery(
        accounts: [.codex: [live]],
        capturedCopies: [live.id: saved]
      )
    )
    let store = harness.store
    await store.reloadAccounts()
    store.monitoredAccounts[.codex] = [live]
    store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .codex)
    let scopeID = try #require(store.notificationScopeID(for: live))
    _ = await harness.controller.process(
      snapshot: weeklySnapshot(now: support.now),
      logicalAccountID: scopeID,
      sourceKind: .api,
      now: support.now
    )
    #expect(harness.center.pendingIDs.count == 1)

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: weeklySnapshot(now: support.now),
        sourceLabel: "Stale",
        sourceKind: .oauth,
        credentialScopeID: replacement.credentialScopeID
      ),
      provider: .codex,
      account: live
    )
    await store.waitForPendingQuotaNotifications()

    #expect(store.notificationScopeIDsByAccountID[saved.id] == scopeID)
    #expect(harness.center.pendingIDs.count == 1)
  }
}

private extension MonitoringScopeEdgeCaseTests {
  func claudeAccount(token: String) -> ProviderAccount {
    ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: nil,
      credentialSource: .claudeKeychain(service: "deferred-scope"),
      credentialIdentity: token
    )
  }

  func codexAccount(identity: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/captured-alias.json"),
      credentialIdentity: identity
    )
  }

  func verifiedProfile(id: String, token: String) -> ClaudeProfile {
    ClaudeProfile(
      accountID: id,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: token)
    )
  }

  func weeklySnapshot(now: Date) -> UsageSnapshot {
    UsageSnapshot(
      provider: .codex,
      secondary: RateWindow(
        kind: .weekly,
        usedPercent: 20,
        resetsAt: now.addingTimeInterval(7 * 24 * 3600)
      ),
      updatedAt: now
    )
  }
}
