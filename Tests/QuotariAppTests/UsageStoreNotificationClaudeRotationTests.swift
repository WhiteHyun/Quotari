import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension UsageStoreNotificationTests {
  @Test func selectedClaudeRegistryResultUsesItsLoadedCredentialStamp() async throws {
    let saved = claudeAccount(name: "Saved Claude login", source: .quotariRegistry(id: "claude:saved"))
    let fetched = claudeAccount(
      name: saved.displayName,
      detail: saved.detail,
      identity: "saved-claude-token",
      source: saved.credentialSource
    )
    let harness = try await makeStore(
      "selected-claude-registry-stamp",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "saved-claude-token") }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-saved-claude-account"
    setClaudeProfile(store, for: saved, accountID: accountID, token: "saved-claude-token")

    applyClaudeFetch(store, scopeID: fetched.credentialScopeID, account: saved)
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }

  @Test func matchedClaudeResultRejectsAPostFetchSlotReplacement() async throws {
    let fetched = claudeAccount(identity: "claude-token-fetched")
    let replacement = claudeAccount(identity: "claude-token-replacement")
    let harness = try await makeStore(
      "matched-claude-post-fetch-replacement",
      providers: [emptyDescriptor(for: .claude)],
      discovery: StaticAccountDiscovery(accounts: [.claude: [fetched]]),
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-token-replacement") }
    )
    let store = harness.store
    let center = harness.center
    await store.reloadAccounts()
    setClaudeProfile(
      store,
      for: replacement,
      accountID: "replacement-claude-account",
      token: "claude-token-replacement"
    )
    let snapshot = UsageSnapshot(
      provider: .claude,
      account: fetched.displayName,
      primary: RateWindow(
        kind: .session,
        usedPercent: 80,
        resetsAt: now.addingTimeInterval(5 * 3600)
      ),
      updatedAt: now
    )

    applyClaudeFetch(store, snapshot: snapshot, scopeID: fetched.credentialScopeID, account: nil)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func automaticClaudeRotationRetriesTheDeferredSnapshotAfterProfileFetch() async throws {
    let beforeRotation = claudeAccount(name: "Claude before rotation", identity: "claude-token-before")
    let afterRotation = claudeAccount(name: "Claude after rotation", identity: "claude-token-after")
    let discovery = MutableAccountDiscovery(
      StaticAccountDiscovery(accounts: [.claude: [beforeRotation]])
    )
    let token = NotificationTokenBox("claude-token-before")
    let harness = try await makeStore(
      "automatic-claude-deferred-profile",
      discovery: discovery,
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-rotating-claude-account"
    setClaudeProfile(store, for: beforeRotation, accountID: accountID, token: "claude-token-before")

    applyClaudeFetch(store, scopeID: beforeRotation.credentialScopeID, account: nil)
    await store.waitForPendingQuotaNotifications()
    let initialResetID = try #require(
      center.attemptedRequests.first(where: { $0.kind == .weeklyReset })?.requestID
    )

    token.value = "claude-token-after"
    discovery.update(StaticAccountDiscovery(accounts: [.claude: [afterRotation]]))
    let deferredSnapshot = claudeRotationSnapshot()
    applyClaudeFetch(store, snapshot: deferredSnapshot, scopeID: afterRotation.credentialScopeID, account: nil)
    await store.waitForPendingQuotaNotifications()

    #expect(center.pendingIDs == [initialResetID])

    setClaudeProfile(store, for: afterRotation, accountID: accountID, token: "claude-token-after")
    store.enqueueClaudeQuotaNotificationScopeRestore()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.filter { $0.kind == .weeklyReset }.count == 2)
    #expect(center.pendingIDs.count == 1)
    #expect(
      center.attemptedRequests.last(where: { $0.kind == .weeklyReset })?.cycleResetAt
        == deferredSnapshot.secondary?.resetsAt
    )
  }

  @Test func replacedClaudeLoginStartsIndependentNotificationHistory() async throws {
    let first = claudeAccount(name: "First Claude login", identity: "claude-access-first")
    let second = claudeAccount(name: "Second Claude login", identity: "claude-access-second")
    let token = NotificationTokenBox("claude-access-first")
    let harness = try await makeStore(
      "replaced-claude-login",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    let center = harness.center
    setClaudeProfile(store, for: first, accountID: "claude-account-first", token: "claude-access-first")

    applyClaudeFetch(store, scopeID: first.credentialScopeID, account: first)
    await store.waitForPendingQuotaNotifications()

    token.value = "claude-access-second"
    setClaudeProfile(store, for: second, accountID: "claude-account-second", token: "claude-access-second")
    applyClaudeFetch(store, scopeID: second.credentialScopeID, account: second)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.map(\.kind) == [.warning, .weeklyReset, .warning, .weeklyReset])
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)).count == 2)
  }

  @Test func claudeAccessTokenRotationPreservesNotificationHistory() async throws {
    let beforeRotation = claudeAccount(name: "Claude Code", detail: "Keychain", identity: "access-token-before")
    let afterRotation = claudeAccount(name: "Claude Code", detail: "Keychain", identity: "access-token-after")
    let token = NotificationTokenBox("access-token-before")
    let harness = try await makeStore(
      "claude-token-rotation",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-claude-account"
    setClaudeProfile(store, for: beforeRotation, accountID: accountID, token: "access-token-before")

    store.applySuccessfulFetch(
      claudeFetchResult(),
      provider: .claude,
      account: beforeRotation
    )
    await store.waitForPendingQuotaNotifications()
    token.value = "access-token-after"
    setClaudeProfile(store, for: afterRotation, accountID: accountID, token: "access-token-after")
    store.applySuccessfulFetch(
      claudeFetchResult(),
      provider: .claude,
      account: afterRotation
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.map(\.kind) == [.warning, .weeklyReset])
    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)) == [logicalAccountID])
  }
}
