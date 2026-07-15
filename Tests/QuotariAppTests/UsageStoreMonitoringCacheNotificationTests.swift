import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MonitoringCacheNotificationTests {
  @Test func cachedOAuthReplayUsesTheProducingCredentialGeneration() async throws {
    let support = UsageStoreNotificationTests()
    let source = ProviderCredentialSource.claudeKeychain(service: "rotating-cache")
    let discovered = claudeAccount(name: "Claude", source: source, token: "old-token")
    let producer = claudeAccount(name: "Claude", source: source, token: "new-token")
    let harness = try await support.makeStore(
      "cached-oauth-producing-generation",
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: "new-token") }
    )
    let store = harness.store
    let result = support.claudeFetchResult(credentialScopeID: producer.credentialScopeID)
    store.monitoredAccounts[.claude] = [discovered]
    store.claudeProfiles[discovered.id] = verifiedProfile(id: "rotating-account", token: "new-token")
    store.accountUsage[.claude] = [
      discovered.id: ProviderAccountUsage(
        snapshot: result.usage,
        sourceLabel: result.sourceLabel,
        sourceKind: result.sourceKind,
        credentialScopeID: result.credentialScopeID
      ),
    ]
    store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .claude)

    store.enqueueCachedAccountUsageNotifications(
      provider: .claude,
      now: Date(),
      excludingAccountIDs: [],
      includingLogicalAccountIDs: nil,
      excludingCredentialScopeIDs: []
    )
    await store.waitForPendingQuotaNotifications()

    #expect(harness.center.attemptedRequests.map(\.kind) == [.warning, .weeklyReset])
  }

  @Test func joinedRefreshDoesNotReplayAnAccountThatStillNeedsFetching() async throws {
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore("joined-refresh-skips-stale-cache")
    let store = harness.store
    let first = support.account(name: "First", path: "/tmp/joined-first.json")
    let second = support.account(name: "Second", path: "/tmp/joined-second.json")
    let now = Date()
    store.refreshInterval = 60
    store.monitoredAccounts[.codex] = [first, second]
    store.accountUsage[.codex] = [
      second.id: ProviderAccountUsage(
        snapshot: notificationSnapshot(
          provider: .codex,
          updatedAt: now.addingTimeInterval(-120),
          resetsAt: now.addingTimeInterval(3600)
        ),
        sourceLabel: "Cached",
        sourceKind: .api
      ),
    ]
    store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .codex)
    let current = AccountUsageRefreshTask(
      task: Task { AccountUsageRefreshOutcome() },
      force: false,
      notifiesQuota: false,
      revision: store.accountRevisions[.codex] ?? 0,
      credentialScopeIDs: [first.credentialScopeID]
    )

    store.enqueueCachedNotificationsAfterJoining(
      current,
      provider: .codex,
      request: AccountUsageRefreshRequest(
        force: false,
        notifiesQuota: true,
        includingLogicalAccountIDs: nil,
        excludingCredentialScopeIDs: []
      )
    )
    await store.waitForPendingQuotaNotifications()

    #expect(harness.center.attemptedRequests.isEmpty)
  }

  @Test func elapsedQuotaResetForcesRefreshInsteadOfReplayingCache() async throws {
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore("elapsed-reset-refreshes-cache")
    let store = harness.store
    let account = support.account(name: "Reset", path: "/tmp/elapsed-reset.json")
    let now = Date()
    store.refreshInterval = 60
    store.monitoredAccounts[.codex] = [account]
    store.accountUsage[.codex] = [
      account.id: ProviderAccountUsage(
        snapshot: notificationSnapshot(
          provider: .codex,
          updatedAt: now.addingTimeInterval(-2),
          resetsAt: now.addingTimeInterval(-1)
        ),
        sourceLabel: "Cached",
        sourceKind: .api
      ),
    ]
    store.synchronizeQuotaNotificationScope(account: nil, origin: nil, provider: .codex)

    let candidates = store.preparedAccountUsageRefreshAccounts(
      .codex,
      now: now,
      request: AccountUsageRefreshRequest(
        force: false,
        notifiesQuota: true,
        includingLogicalAccountIDs: nil,
        excludingCredentialScopeIDs: []
      )
    )
    await store.waitForPendingQuotaNotifications()

    #expect(candidates == [account])
    #expect(harness.center.attemptedRequests.isEmpty)
  }
}

private extension MonitoringCacheNotificationTests {
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

  func verifiedProfile(id: String, token: String) -> ClaudeProfile {
    ClaudeProfile(
      accountID: id,
      fingerprint: ProviderCredentialIdentity.fingerprint(of: token)
    )
  }

  func notificationSnapshot(
    provider: UsageProvider,
    updatedAt: Date,
    resetsAt: Date
  ) -> UsageSnapshot {
    UsageSnapshot(
      provider: provider,
      primary: RateWindow(
        kind: .session,
        usedPercent: 80,
        resetsAt: resetsAt
      ),
      updatedAt: updatedAt
    )
  }
}
