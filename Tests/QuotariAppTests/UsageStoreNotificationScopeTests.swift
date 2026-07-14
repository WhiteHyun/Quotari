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
    let first = codexAccount(name: "First login", identity: "acct-first", path: path)
    let second = codexAccount(name: "Second login", identity: "acct-second", path: path)
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

    applyLiveCodexFetch(store, scopeID: first.credentialScopeID)
    await store.waitForPendingQuotaNotifications()
    #expect(center.attemptedRequests.count == 1)

    discovery.update(StaticAccountDiscovery(accounts: [.codex: [second]]))
    applyLiveCodexFetch(store, scopeID: second.credentialScopeID)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 2)
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)).count == 2)
  }

  @Test func automaticResultRejectsAPostFetchSlotReplacement() async throws {
    let path = "/tmp/post-fetch-replacement.json"
    let fetchedAccount = codexAccount(name: "Fetched login", identity: "acct-fetched", path: path)
    let replacement = codexAccount(name: "Replacement login", identity: "acct-replacement", path: path)
    let harness = try await makeStore(
      "post-fetch-slot-replacement",
      providers: [emptyDescriptor(for: .codex)],
      discovery: StaticAccountDiscovery(accounts: [.codex: [replacement]])
    )
    let store = harness.store
    let center = harness.center

    applyLiveCodexFetch(store, scopeID: fetchedAccount.credentialScopeID)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func automaticCodexResultMatchesItsCredentialAmongMultipleSlots() async throws {
    let fetched = codexAccount(name: "Default login", identity: "acct-default", path: "/tmp/default-auth.json")
    let other = codexAccount(name: "CODEX_HOME login", identity: "acct-codex-home", path: "/tmp/codex-home-auth.json")
    let harness = try await makeStore(
      "multiple-codex-slots",
      providers: [emptyDescriptor(for: .codex)],
      discovery: StaticAccountDiscovery(accounts: [.codex: [fetched, other]])
    )
    let store = harness.store
    let center = harness.center

    applyLiveCodexFetch(store, scopeID: fetched.credentialScopeID)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == fetched.credentialScopeID)
  }

  @Test func selectedCodexRegistryResultUsesItsLoadedCredentialStamp() async throws {
    let saved = account(
      name: "Saved Codex login",
      source: .quotariRegistry(id: "codex:saved")
    )
    let fetched = ProviderAccount(
      provider: .codex,
      displayName: saved.displayName,
      detail: saved.detail,
      credentialSource: saved.credentialSource,
      credentialIdentity: "acct-saved"
    )
    let harness = try await makeStore(
      "selected-codex-registry-stamp",
      codexCredentialLoader: { _ in
        CodexCredentials(accessToken: "codex-token", accountID: "acct-saved")
      }
    )
    let store = harness.store
    let center = harness.center

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Codex",
        sourceKind: .oauth,
        credentialScopeID: fetched.credentialScopeID
      ),
      provider: .codex,
      account: saved
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == saved.id)
  }

  @Test func selectionChangeRejectsDelayedAutomaticAttribution() async throws {
    let automatic = codexAccount(
      name: "Automatic",
      identity: "automatic-account",
      path: "/tmp/delayed-automatic.json"
    )
    let selected = codexAccount(name: "Selected", identity: "selected-account", path: "/tmp/selected.json")
    let discovery = GatedNotificationAccountDiscovery(account: automatic)
    let harness = try await makeStore(
      "delayed-automatic-attribution",
      discovery: discovery
    )
    let store = harness.store
    let center = harness.center

    applyLiveCodexFetch(store, scopeID: automatic.credentialScopeID)
    await discovery.waitUntilRequestStarts()

    store.selectAccount(selected, for: .codex)
    await discovery.resume()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func accountlessAutomaticCodexOAuthUsesItsOnlyDiscoveredLiveSlot() async throws {
    let live = codexAccount(name: "Codex account", identity: "acct-id-only", path: "/tmp/account-id-only-auth.json")
    let harness = try await makeStore(
      "accountless-codex-oauth",
      providers: [emptyDescriptor(for: .codex)],
      discovery: StaticAccountDiscovery(accounts: [.codex: [live]])
    )
    let store = harness.store
    let center = harness.center
    await store.reloadAccounts()

    applyLiveCodexFetch(store, scopeID: live.credentialScopeID)
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
  }
}
