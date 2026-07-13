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

  @Test func automaticCodexResultMatchesItsCredentialAmongMultipleSlots() async throws {
    let fetched = ProviderAccount(
      provider: .codex,
      displayName: "Default login",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/default-auth.json"),
      credentialIdentity: "acct-default"
    )
    let other = ProviderAccount(
      provider: .codex,
      displayName: "CODEX_HOME login",
      detail: nil,
      credentialSource: .codexAuthFile(path: "/tmp/codex-home-auth.json"),
      credentialIdentity: "acct-codex-home"
    )
    let harness = try await makeStore(
      "multiple-codex-slots",
      providers: [emptyDescriptor(for: .codex)],
      discovery: StaticAccountDiscovery(accounts: [.codex: [fetched, other]])
    )
    let store = harness.store
    let center = harness.center

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: usage(accountName: nil),
        sourceLabel: "Live",
        sourceKind: .oauth,
        credentialScopeID: fetched.credentialScopeID
      ),
      provider: .codex,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == fetched.credentialScopeID)
  }

  @Test func automaticClaudeCapturedCopyUsesTheLiveVerifiedProfile() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let live = ProviderAccount(
      provider: .claude,
      displayName: "Live Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-live-token"
    )
    let saved = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude login",
      detail: nil,
      credentialSource: .quotariRegistry(id: "claude:saved")
    )
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
    store.claudeProfiles[live.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-live-token")
    )

    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: live.credentialScopeID),
      provider: .claude,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }

  @Test func reconciledClaudeSelectionUsesTheLiveVerifiedProfile() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let live = ProviderAccount(
      provider: .claude,
      displayName: "Live Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-live-token"
    )
    let saved = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude login",
      detail: nil,
      credentialSource: .quotariRegistry(id: "claude:saved")
    )
    let harness = try await makeStore(
      "reconciled-claude-profile",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-live-token") }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-reconciled-claude-account"
    store.reconciledSelectionOrigins[.claude] = saved
    store.claudeProfiles[live.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-live-token")
    )

    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: live.credentialScopeID),
      provider: .claude,
      account: live
    )
    await store.waitForPendingQuotaNotifications()

    let logicalAccountID = "claude:account:\(ProviderCredentialIdentity.fingerprint(of: "id:\(accountID)"))"
    #expect(center.attemptedRequests.map(\.key.logicalAccountID) == [logicalAccountID, logicalAccountID])
  }

  @Test func selectedClaudeResultRejectsAPostFetchSlotReplacement() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let fetched = ProviderAccount(
      provider: .claude,
      displayName: "Fetched Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-token-fetched"
    )
    let replacement = ProviderAccount(
      provider: .claude,
      displayName: "Replacement Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-token-replacement"
    )
    let harness = try await makeStore(
      "selected-claude-post-fetch-replacement",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-token-replacement") }
    )
    let store = harness.store
    let center = harness.center
    store.claudeProfiles[replacement.id] = ClaudeProfile(
      accountID: "replacement-claude-account",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-token-replacement")
    )

    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: fetched.credentialScopeID),
      provider: .claude,
      account: fetched
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func matchedClaudeResultRejectsAPostFetchSlotReplacement() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let fetched = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-token-fetched"
    )
    let replacement = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-token-replacement"
    )
    let harness = try await makeStore(
      "matched-claude-post-fetch-replacement",
      providers: [emptyDescriptor(for: .claude)],
      discovery: StaticAccountDiscovery(accounts: [.claude: [fetched]]),
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "claude-token-replacement") }
    )
    let store = harness.store
    let center = harness.center
    await store.reloadAccounts()
    store.claudeProfiles[replacement.id] = ClaudeProfile(
      accountID: "replacement-claude-account",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-token-replacement")
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

    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: snapshot,
        sourceLabel: "Claude",
        sourceKind: .oauth,
        credentialScopeID: fetched.credentialScopeID
      ),
      provider: .claude,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)
  }

  @Test func automaticClaudeRotationRetriesTheDeferredSnapshotAfterProfileFetch() async throws {
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let beforeRotation = ProviderAccount(
      provider: .claude,
      displayName: "Claude before rotation",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-token-before"
    )
    let afterRotation = ProviderAccount(
      provider: .claude,
      displayName: "Claude after rotation",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-token-after"
    )
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
    store.claudeProfiles[beforeRotation.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-token-before")
    )

    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: beforeRotation.credentialScopeID),
      provider: .claude,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()
    let initialResetID = try #require(
      center.attemptedRequests.first(where: { $0.kind == .weeklyReset })?.requestID
    )

    token.value = "claude-token-after"
    discovery.update(StaticAccountDiscovery(accounts: [.claude: [afterRotation]]))
    let deferredSnapshot = UsageSnapshot(
      provider: .claude,
      primary: RateWindow(
        kind: .session,
        usedPercent: 80,
        resetsAt: now.addingTimeInterval(6 * 3600)
      ),
      secondary: RateWindow(
        kind: .weekly,
        usedPercent: 20,
        resetsAt: now.addingTimeInterval(8 * 24 * 3600)
      ),
      updatedAt: now.addingTimeInterval(60)
    )
    store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: deferredSnapshot,
        sourceLabel: "Claude",
        sourceKind: .oauth,
        credentialScopeID: afterRotation.credentialScopeID
      ),
      provider: .claude,
      account: nil
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.pendingIDs == [initialResetID])

    store.claudeProfiles[afterRotation.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-token-after")
    )
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
    let source = ProviderCredentialSource.claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    )
    let first = ProviderAccount(
      provider: .claude,
      displayName: "First Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-access-first"
    )
    let second = ProviderAccount(
      provider: .claude,
      displayName: "Second Claude login",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "claude-access-second"
    )
    let token = NotificationTokenBox("claude-access-first")
    let harness = try await makeStore(
      "replaced-claude-login",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    let center = harness.center
    store.claudeProfiles[first.id] = ClaudeProfile(
      accountID: "claude-account-first",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-access-first")
    )

    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: first.credentialScopeID),
      provider: .claude,
      account: first
    )
    await store.waitForPendingQuotaNotifications()

    token.value = "claude-access-second"
    store.claudeProfiles[second.id] = ClaudeProfile(
      accountID: "claude-account-second",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-access-second")
    )
    store.applySuccessfulFetch(
      claudeFetchResult(credentialScopeID: second.credentialScopeID),
      provider: .claude,
      account: second
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.map(\.kind) == [.warning, .weeklyReset, .warning, .weeklyReset])
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
    let token = NotificationTokenBox("access-token-before")
    let harness = try await makeStore(
      "claude-token-rotation",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    let center = harness.center
    let accountID = "stable-claude-account"
    store.claudeProfiles[beforeRotation.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "access-token-before")
    )

    store.applySuccessfulFetch(
      claudeFetchResult(),
      provider: .claude,
      account: beforeRotation
    )
    await store.waitForPendingQuotaNotifications()
    token.value = "access-token-after"
    store.claudeProfiles[afterRotation.id] = ClaudeProfile(
      accountID: accountID,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "access-token-after")
    )
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

private final class NotificationTokenBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: String

  init(_ value: String) {
    storage = value
  }

  var value: String {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
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
