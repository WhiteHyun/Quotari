import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringFinalReviewTests {
  @Test func unattributedAutomaticRefreshDoesNotSuppressTheActiveMonitoredAccount() async throws {
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]]
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refresh()

    let names = await fixture.recorder.names
    #expect(names.first == "Automatic")
    #expect(Set(names.dropFirst()) == ["Personal", "Work"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal)?.snapshot != nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func unavailableSelectionPlaceholderIsNotReportedAsCLIActive() async throws {
    let fixture = try MonitoringFixture(
      accounts: [],
      selected: [.codex: MonitoringFixture.personal],
      monitored: [.codex: []]
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.accounts[.codex] == [MonitoringFixture.personal])
    #expect(fixture.store.activeCLIAccount(for: .codex) == nil)
  }

  @Test func periodicRefreshDeliversQuotaAlertsForEveryMonitoredAccount() async throws {
    let support = UsageStoreNotificationTests()
    let first = support.account(name: "First", path: "/tmp/monitored-first-auth.json")
    let second = support.account(name: "Second", path: "/tmp/monitored-second-auth.json")
    let strategy = MonitoredNotificationUsageStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0, 0),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let harness = try await support.makeStore(
      "periodic-monitored-alerts",
      providers: [descriptor],
      discovery: StaticAccountDiscovery(accounts: [.codex: [first, second]])
    )
    let store = harness.store
    await store.reloadAccounts()
    store.selectAccount(first, for: .codex)

    await store.refresh()
    await store.waitForPendingQuotaNotifications()

    let logicalAccountIDs = Set(harness.center.attemptedRequests.map(\.key.logicalAccountID))
    #expect(logicalAccountIDs == [first.id, second.id])
  }

  @Test func reactivationDeliversAlertsForEveryMonitoredAccount() async throws {
    let fixture = try await notificationFixture("reactivation-monitored-alerts")
    let store = fixture.store
    await store.reloadAccounts()
    store.selectAccount(fixture.first, for: .codex)

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    await store.selectionRefreshTasks[.codex]?.value
    await store.waitForPendingQuotaNotifications()

    #expect(Set(fixture.center.attemptedRequests.map(\.key.logicalAccountID)) == [
      fixture.first.id, fixture.second.id,
    ])
  }

  @Test func periodicRefreshEvaluatesFreshMonitoredCache() async throws {
    let fixture = try await notificationFixture("cached-monitored-alerts")
    let store = fixture.store
    await store.reloadAccounts()
    await store.refreshAccountUsage(for: .codex, force: true)
    #expect(fixture.center.attemptedRequests.isEmpty)

    await store.refresh()
    await store.waitForPendingQuotaNotifications()

    #expect(Set(fixture.center.attemptedRequests.map(\.key.logicalAccountID)) == [
      fixture.first.id, fixture.second.id,
    ])
  }

  private func notificationFixture(_ name: String) async throws -> MonitoredNotificationFixture {
    let support = UsageStoreNotificationTests()
    let first = support.account(name: "First", path: "/tmp/\(name)-first.json")
    let second = support.account(name: "Second", path: "/tmp/\(name)-second.json")
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0, 0),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [MonitoredNotificationUsageStrategy()] }
    )
    let harness = try await support.makeStore(
      name,
      providers: [descriptor],
      discovery: StaticAccountDiscovery(accounts: [.codex: [first, second]])
    )
    return MonitoredNotificationFixture(
      store: harness.store,
      center: harness.center,
      first: first,
      second: second
    )
  }
}

private struct MonitoredNotificationFixture {
  let store: UsageStore
  let center: UsageNotificationCenterStub
  let first: ProviderAccount
  let second: ProviderAccount
}

private struct MonitoredNotificationUsageStrategy: ProviderFetchStrategy {
  let id = "monitored-notification-usage"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        account: context.account?.displayName,
        primary: RateWindow(
          kind: .session,
          usedPercent: 80,
          resetsAt: context.now.addingTimeInterval(3600)
        ),
        updatedAt: context.now
      ),
      sourceLabel: "Live",
      sourceKind: kind,
      credentialScopeID: context.account?.credentialScopeID
    )
  }
}
