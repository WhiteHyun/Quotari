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
