import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MonitoringNotificationSafetyTests {
  @Test func unattributedAutomaticResultPreservesMonitoredReset() async throws {
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore("unattributed-preserves-monitor")
    let account = support.account(name: "Monitored", path: "/tmp/monitored-reset-auth.json")
    harness.store.monitoredAccounts[.codex] = [account]
    harness.store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .codex)
    _ = await harness.controller.process(
      snapshot: weeklySnapshot(now: support.now),
      logicalAccountID: account.id,
      sourceKind: .api,
      now: support.now
    )

    harness.store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: support.usage(accountName: nil),
        sourceLabel: "Stale automatic",
        sourceKind: .oauth,
        credentialScopeID: "unknown-credential"
      ),
      provider: .codex,
      account: nil
    )
    await harness.store.waitForPendingQuotaNotifications()

    #expect(harness.center.pendingIDs.count == 1)
  }

  @Test func staleAliasKeepsSharedManagedAccountReset() async throws {
    let support = UsageStoreNotificationTests()
    let firstSource = ProviderCredentialSource.claudeKeychain(service: "first-alias")
    let secondSource = ProviderCredentialSource.claudeCredentialsFile(path: "/tmp/second-alias.json")
    let first = claudeAccount(name: "First", source: firstSource, token: "first-token")
    let second = claudeAccount(name: "Second", source: secondSource, token: "second-token")
    let firstToken = NotificationTokenBox("first-token")
    let harness = try await support.makeStore(
      "stale-alias-keeps-shared-reset",
      claudeCredentialLoader: { source in
        if source == firstSource {
          return ClaudeCredentials(accessToken: firstToken.value)
        }
        if source == secondSource {
          return ClaudeCredentials(accessToken: "second-token")
        }
        return nil
      }
    )
    let accountID = "shared-claude-account"
    harness.store.claudeProfiles[first.id] = verifiedProfile(id: accountID, token: "first-token")
    harness.store.claudeProfiles[second.id] = verifiedProfile(id: accountID, token: "second-token")
    harness.store.monitoredAccounts[.claude] = [first, second]
    harness.store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .claude)
    let logicalAccountID = try #require(harness.store.notificationScopeID(for: first))
    _ = await harness.controller.process(
      snapshot: support.claudeFetchResult().usage,
      logicalAccountID: logicalAccountID,
      sourceKind: .api,
      now: support.now
    )
    #expect(harness.store.notificationScopeIDsByAccountID[first.id] == logicalAccountID)
    #expect(harness.store.notificationScopeIDsByAccountID[second.id] == logicalAccountID)
    #expect(harness.center.pendingIDs.count == 1)

    firstToken.value = "replacement-token"
    harness.store.applySuccessfulFetch(
      support.claudeFetchResult(credentialScopeID: first.credentialScopeID),
      provider: .claude,
      account: first
    )
    await harness.store.waitForPendingQuotaNotifications()

    #expect(harness.center.pendingIDs.count == 1)
  }

  @Test func everyDeferredClaudeMonitorReplaysAfterProfileResolution() async throws {
    let firstToken = "first-claude-token"
    let secondToken = "second-claude-token"
    let first = claudeAccount(
      name: "First",
      source: .claudeKeychain(service: "first-service"),
      token: firstToken
    )
    let second = claudeAccount(
      name: "Second",
      source: .claudeCredentialsFile(path: "/tmp/second-claude.json"),
      token: secondToken
    )
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore(
      "multiple-deferred-claude-monitors",
      claudeCredentialLoader: { source in
        switch source {
        case .claudeKeychain:
          ClaudeCredentials(accessToken: firstToken)
        case .claudeCredentialsFile:
          ClaudeCredentials(accessToken: secondToken)
        case .codexAuthFile, .codexKeychain, .claudeEnvironment, .quotariRegistry:
          nil
        }
      }
    )
    let store = harness.store
    store.setMonitoring(true, for: first)
    store.setMonitoring(true, for: second)

    enqueueClaudeNotification(for: first, support: support, store: store)
    enqueueClaudeNotification(for: second, support: support, store: store)
    await store.waitForPendingQuotaNotifications()
    #expect(store.deferredClaudeQuotaNotifications.count == 2)

    store.claudeProfiles[first.id] = verifiedProfile(id: "first", token: firstToken)
    store.claudeProfiles[second.id] = verifiedProfile(id: "second", token: secondToken)
    store.enqueueClaudeQuotaNotificationScopeRestore()
    await store.waitForPendingQuotaNotifications()

    #expect(store.deferredClaudeQuotaNotifications.isEmpty)
    #expect(Set(harness.center.attemptedRequests.map(\.key.logicalAccountID)).count == 2)
  }

  @Test func emptyProfileDrainsDeferredMonitorAndClearsItsStaleReset() async throws {
    let support = UsageStoreNotificationTests()
    let source = ProviderCredentialSource.claudeKeychain(service: "empty-profile-monitor")
    let token = NotificationTokenBox("old-token")
    let account = claudeAccount(name: "Monitored", source: source, token: token.value)
    let harness = try await support.makeStore(
      "empty-profile-clears-monitored-reset",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: token.value) }
    )
    let store = harness.store
    store.monitoredAccounts[.claude] = [account]
    store.claudeProfiles[account.id] = verifiedProfile(id: "old-account", token: token.value)
    store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .claude)
    let oldScopeID = try #require(store.notificationScopeID(for: account))
    _ = await harness.controller.process(
      snapshot: support.claudeFetchResult().usage,
      logicalAccountID: oldScopeID,
      sourceKind: .oauth,
      now: support.now
    )
    #expect(harness.center.pendingIDs.count == 1)

    token.value = "replacement-token"
    let replacement = claudeAccount(name: "Replacement", source: source, token: token.value)
    store.applySuccessfulFetch(
      support.claudeFetchResult(credentialScopeID: replacement.credentialScopeID),
      provider: .claude,
      account: account
    )
    await store.waitForPendingQuotaNotifications()
    #expect(store.deferredClaudeQuotaNotifications[account.id] != nil)

    store.claudeProfiles[account.id] = nil
    store.emptyClaudeProfileFingerprints[account.id] = ProviderCredentialIdentity.fingerprint(
      of: token.value
    )
    store.enqueueClaudeQuotaNotificationScopeRestore()
    await store.waitForPendingQuotaNotifications()

    let oldKey = QuotaNotificationWindowKey(
      provider: .claude,
      logicalAccountID: oldScopeID,
      window: .weekly
    )
    #expect(store.deferredClaudeQuotaNotifications[account.id] == nil)
    #expect(store.notificationScopeIDsByAccountID[account.id] == nil)
    #expect(harness.controller.ledger.windows[oldKey]?.scheduledReset == nil)
    #expect(harness.center.pendingIDs.isEmpty)
  }

  @Test func staleMonitoredCredentialKeepsOtherAccountsResetScheduled() async throws {
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore("stale-monitor-keeps-other-scope")
    let first = support.account(name: "First", path: "/tmp/stale-first-auth.json")
    let second = support.account(name: "Second", path: "/tmp/valid-second-auth.json")
    let replacement = support.account(name: "Replacement", path: "/tmp/stale-first-auth.json")
    let snapshot = weeklySnapshot(now: support.now)
    harness.store.monitoredAccounts[.codex] = [first, second]
    harness.store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .codex)
    await scheduleWeeklyResets(
      for: [first, second], snapshot: snapshot,
      controller: harness.controller, now: support.now
    )

    harness.store.applySuccessfulFetch(
      ProviderFetchResult(
        usage: snapshot,
        sourceLabel: "Stale",
        sourceKind: .oauth,
        credentialScopeID: replacement.credentialScopeID
      ),
      provider: .codex,
      account: first
    )
    await harness.store.waitForPendingQuotaNotifications()

    let firstKey = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: first.id,
      window: .weekly
    )
    let secondKey = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: second.id,
      window: .weekly
    )
    #expect(harness.controller.ledger.windows[firstKey]?.scheduledReset == nil)
    #expect(harness.controller.ledger.windows[secondKey]?.scheduledReset != nil)
    #expect(harness.center.pendingIDs.count == 1)

    harness.store.applySuccessfulFetch(
      ProviderFetchResult(usage: snapshot, sourceLabel: "Recovered", sourceKind: .api),
      provider: .codex,
      account: first
    )
    await harness.store.waitForPendingQuotaNotifications()

    #expect(harness.controller.ledger.windows[firstKey]?.scheduledReset != nil)
    #expect(harness.center.pendingIDs.count == 2)
  }
}

private extension MonitoringNotificationSafetyTests {
  func scheduleWeeklyResets(
    for accounts: [ProviderAccount],
    snapshot: UsageSnapshot,
    controller: QuotaNotificationController,
    now: Date
  ) async {
    for account in accounts {
      _ = await controller.process(
        snapshot: snapshot,
        logicalAccountID: account.id,
        sourceKind: .api,
        now: now
      )
    }
  }

  func claudeAccount(
    name: String,
    source: ProviderCredentialSource,
    token: String
  ) -> ProviderAccount {
    ProviderAccount(
      provider: .claude,
      displayName: name,
      detail: nil,
      credentialSource: source,
      credentialIdentity: token
    )
  }

  func enqueueClaudeNotification(
    for account: ProviderAccount,
    support: UsageStoreNotificationTests,
    store: UsageStore
  ) {
    let result = support.claudeFetchResult(credentialScopeID: account.credentialScopeID)
    store.enqueueQuotaNotification(
      snapshot: result.usage,
      provider: .claude,
      account: account,
      sourceKind: result.sourceKind,
      credentialScopeID: result.credentialScopeID
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
