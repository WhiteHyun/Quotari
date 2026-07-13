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
        sourceKind: .oauth,
        credentialScopeID: first.credentialScopeID
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
        sourceKind: .oauth,
        credentialScopeID: second.credentialScopeID
      ),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 2)
    #expect(Set(center.attemptedRequests.map(\.key.logicalAccountID)).count == 2)
  }

  @Test func automaticResultRejectsAPostFetchSlotReplacement() async throws {
    let path = "/tmp/post-fetch-replacement.json"
    let fetchedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Fetched login",
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: "acct-fetched"
    )
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement login",
      detail: nil,
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: "acct-replacement"
    )
    let harness = try await makeStore(
      "post-fetch-slot-replacement",
      providers: [emptyDescriptor(for: .codex)],
      discovery: StaticAccountDiscovery(accounts: [.codex: [replacement]])
    )
    let store = harness.store
    let center = harness.center

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth,
        credentialScopeID: fetchedAccount.credentialScopeID
      ),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
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

  @Test func selectionChangeRejectsDelayedAutomaticAttribution() async throws {
    let automatic = ProviderAccount(
      provider: .codex,
      displayName: "Automatic",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/delayed-automatic.json"),
      credentialIdentity: "automatic-account"
    )
    let selected = ProviderAccount(
      provider: .codex,
      displayName: "Selected",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/selected.json"),
      credentialIdentity: "selected-account"
    )
    let discovery = GatedNotificationAccountDiscovery(account: automatic)
    let harness = try await makeStore(
      "delayed-automatic-attribution",
      discovery: discovery
    )
    let store = harness.store
    let center = harness.center

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth,
        credentialScopeID: automatic.credentialScopeID
      ),
      provider: .codex,
      account: nil
    )
    await discovery.waitUntilRequestStarts()

    store.selectAccount(selected, for: .codex)
    await discovery.resume()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
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
        sourceKind: .oauth,
        credentialScopeID: live.credentialScopeID
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

private actor GatedNotificationAccountDiscovery: ProviderAccountDiscovering {
  private let account: ProviderAccount
  private var requestStarted = false
  private var isReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(account: ProviderAccount) {
    self.account = account
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    requestStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    if !isReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return account.provider == provider ? [account] : []
  }

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resume() {
    isReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
