@testable import Quotari
import Testing

@MainActor
struct MonitoringRevisionNotificationTests {
  @Test func invalidatedAccountUsageGenerationCannotEnqueueQuotaAlerts() async throws {
    let support = UsageStoreNotificationTests()
    let harness = try await support.makeStore("invalidated-monitored-generation")
    let store = harness.store
    let account = support.account(name: "Old", path: "/tmp/old-generation-auth.json")
    store.monitoredAccounts[.codex] = [account]
    let oldRevision = store.accountRevisions[.codex] ?? 0
    store.accountRevisions[.codex, default: 0] &+= 1
    let result = support.fetchResult(accountName: account.displayName)

    store.completeAccountUsageRefresh(
      AccountUsageRefreshOutcome(
        notificationCandidates: [
          AccountUsageNotificationCandidate(account: account, result: result),
        ]
      ),
      provider: .codex,
      canNotifyQuota: store.accountUsageRefreshCanNotify(
        .codex,
        revision: oldRevision,
        isCancelled: false
      )
    )
    await store.waitForPendingQuotaNotifications()

    #expect(harness.center.attemptedRequests.isEmpty)
  }

  @Test func notifyingRefreshRetriesEveryMonitorAfterSelectionInvalidatesRevision() async throws {
    let gate = MonitoringUsageGate()
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.work]],
      strategyGate: gate
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    let notifying = Task {
      await fixture.store.refreshAccountUsage(
        for: .codex,
        force: true,
        notifiesQuota: true
      )
    }
    await gate.waitUntilFirstRequestStarts()
    fixture.store.selectAccount(MonitoringFixture.personal, for: .codex)
    await gate.resumeFirstRequest()
    await notifying.value
    await fixture.store.selectionRefreshTasks[.codex]?.value

    let names = await fixture.recorder.names
    #expect(names.filter { $0 == "Work" }.count == 2)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func notifyingJoinReplacesAnInvalidatedNonNotifyingRefresh() async throws {
    let gate = MonitoringUsageGate()
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.work]],
      strategyGate: gate
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    let stale = Task {
      await fixture.store.refreshAccountUsage(for: .codex, force: true)
    }
    await gate.waitUntilFirstRequestStarts()
    fixture.store.selectAccount(MonitoringFixture.personal, for: .codex)
    let notifying = Task {
      await fixture.store.refreshAccountUsage(
        for: .codex,
        force: true,
        notifiesQuota: true
      )
    }
    await gate.resumeFirstRequest()
    await stale.value
    await notifying.value
    await fixture.store.selectionRefreshTasks[.codex]?.value

    let names = await fixture.recorder.names
    #expect(names.filter { $0 == "Work" }.count == 2)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }
}
