import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension UsageStoreNotificationTests {
  @Test func automaticClaudeResultRejectsAProfileFromAPostDiscoveryReplacement() async throws {
    let discovered = claudeAccount(name: "Discovered Claude login", identity: "claude-token-discovered")
    let replacement = claudeAccount(name: "Replacement Claude login", identity: "claude-token-replacement")
    let harness = try await makeStore(
      "automatic-claude-post-discovery-replacement",
      discovery: StaticAccountDiscovery(accounts: [.claude: [discovered]]),
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-token-replacement") }
    )
    let store = harness.store
    let center = harness.center
    setClaudeProfile(
      store,
      for: replacement,
      accountID: "replacement-claude-account",
      token: "claude-token-replacement"
    )

    applyClaudeFetch(store, scopeID: discovered.credentialScopeID, account: nil)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func automaticClaudeCapturedCopyUsesTheLiveVerifiedProfile() async throws {
    let live = claudeAccount(name: "Live Claude login", identity: "claude-live-token")
    let saved = claudeAccount(name: "Saved Claude login", source: .quotariRegistry(id: "claude:saved"))
    let discovery = StaticAccountDiscovery(
      accounts: [.claude: [live]],
      capturedCopies: [live.id: saved]
    )
    let harness = try await makeStore(
      "captured-claude-profile",
      discovery: discovery,
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-live-token") }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-captured-claude-account"
    setClaudeProfile(store, for: live, accountID: accountID, token: "claude-live-token")

    applyClaudeFetch(store, scopeID: live.credentialScopeID, account: nil)
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }

  @Test func reconciledClaudeSelectionUsesTheLiveVerifiedProfile() async throws {
    let live = claudeAccount(name: "Live Claude login", identity: "claude-live-token")
    let saved = claudeAccount(name: "Saved Claude login", source: .quotariRegistry(id: "claude:saved"))
    let harness = try await makeStore(
      "reconciled-claude-profile",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-live-token") }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-reconciled-claude-account"
    store.reconciledSelectionOrigins[.claude] = saved
    setClaudeProfile(store, for: live, accountID: accountID, token: "claude-live-token")

    applyClaudeFetch(store, scopeID: live.credentialScopeID, account: live)
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }

  @Test func selectedClaudeResultRejectsAPostFetchSlotReplacement() async throws {
    let fetched = claudeAccount(name: "Fetched Claude login", identity: "claude-token-fetched")
    let replacement = claudeAccount(name: "Replacement Claude login", identity: "claude-token-replacement")
    let token = NotificationTokenBox("claude-token-fetched")
    let harness = try await makeStore(
      "selected-claude-post-fetch-replacement",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    let controller = harness.controller
    let center = harness.center
    setClaudeProfile(store, for: fetched, accountID: "fetched-claude-account", token: "claude-token-fetched")
    store.synchronizeQuotaNotificationScope(
      account: fetched,
      origin: nil,
      provider: .claude
    )
    applyClaudeFetch(store, scopeID: fetched.credentialScopeID, account: fetched)
    await store.waitForPendingQuotaNotifications()
    let scheduledReset = try #require(
      center.attemptedRequests.first(where: { $0.kind == .weeklyReset })
    )
    #expect(center.pendingIDs == [scheduledReset.requestID])

    token.value = "claude-token-replacement"
    setClaudeProfile(
      store,
      for: replacement,
      accountID: "replacement-claude-account",
      token: "claude-token-replacement"
    )

    applyClaudeFetch(store, scopeID: fetched.credentialScopeID, account: fetched)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 2)
    #expect(center.pendingIDs.isEmpty)
    #expect(controller.ledger.windows[scheduledReset.key]?.scheduledReset == nil)
  }

  @Test func selectedClaudeRotationAcceptsTheFinalFetchCredential() async throws {
    let selectedBeforeRotation = claudeAccount(name: "Claude before rotation", identity: "claude-token-before")
    let finalCredential = claudeAccount(name: "Claude after rotation", identity: "claude-token-after")
    let harness = try await makeStore(
      "selected-claude-final-fetch-credential",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-token-after") }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-selected-claude-account"
    setClaudeProfile(store, for: selectedBeforeRotation, accountID: accountID, token: "claude-token-after")

    applyClaudeFetch(store, scopeID: finalCredential.credentialScopeID, account: selectedBeforeRotation)
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }
}
