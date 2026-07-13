import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
extension UsageStoreNotificationTests {
  @Test func reenablingAProviderRestoresTheSelectedAccountsNotificationScope() async throws {
    let harness = try await makeStore("provider-reactivation")
    let store = harness.store
    let center = harness.center
    let selected = account(name: "Selected", path: "/tmp/reactivated-auth.json")
    store.selectAccount(selected, for: .codex)

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == selected.id)
  }

  @Test func reactivationScopeRestoreUsesTheLatestLogicalOrigin() async throws {
    let harness = try await makeStore("provider-reactivation-origin-change")
    let store = harness.store
    let center = harness.center
    let selected = account(name: "Selected", path: "/tmp/reactivated-live-auth.json")
    let captured = account(name: "Captured", source: .quotariRegistry(id: "codex:captured"))
    store.selectAccount(selected, for: .codex, standingInFor: captured)
    let gate = UsageNotificationQueueGate()
    store.quotaNotificationTask = Task { await gate.wait() }

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    store.selectAccount(selected, for: .codex, standingInFor: nil)
    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await gate.release()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == selected.id)
  }

  @Test func inFlightNotificationCannotSurviveProviderReactivationAndScopeRestore() async throws {
    let harness = try await makeStore("provider-reactivation-in-flight-notification")
    let store = harness.store
    let center = harness.center
    let selected = account(name: "Selected", path: "/tmp/reactivated-in-flight-auth.json")
    store.selectAccount(selected, for: .codex)
    let gate = UsageNotificationQueueGate()
    center.authorizationGate = gate

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await gate.waitUntilBlocked()
    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    store.selectAccount(selected, for: .codex)
    await gate.release()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await store.waitForPendingQuotaNotifications()
    #expect(center.attemptedRequests.count == 1)
  }

  @Test func inFlightNotificationFailureCannotPublishAfterProviderReactivation() async throws {
    let harness = try await makeStore("provider-reactivation-in-flight-notification-failure")
    let store = harness.store
    let center = harness.center
    let selected = account(name: "Selected", path: "/tmp/reactivated-in-flight-failure-auth.json")
    store.selectAccount(selected, for: .codex)
    let gate = UsageNotificationQueueGate()
    center.addGate = gate
    center.addError = CocoaError(.fileWriteUnknown)

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await gate.waitUntilBlocked()
    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    store.selectAccount(selected, for: .codex)
    await gate.release()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(harness.controller.lastError == nil)
  }

  @Test func inFlightImmediateNotificationIsRetractedAfterProviderReactivation() async throws {
    let harness = try await makeStore("provider-reactivation-in-flight-notification-success")
    let store = harness.store
    let center = harness.center
    let selected = account(name: "Selected", path: "/tmp/reactivated-in-flight-success-auth.json")
    store.selectAccount(selected, for: .codex)
    let gate = UsageNotificationQueueGate()
    center.addGate = gate

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await gate.waitUntilBlocked()
    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    store.selectAccount(selected, for: .codex)
    await gate.release()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.deliveredIDs.isEmpty)

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await store.waitForPendingQuotaNotifications()
    #expect(center.attemptedRequests.count == 2)
    #expect(center.deliveredIDs.count == 1)
  }

  @Test func reenablingDoesNotDeliverAQueuedPreDisableSnapshot() async throws {
    let harness = try await makeStore("provider-reactivation-stale-result")
    let store = harness.store
    let center = harness.center
    let selected = account(name: "Selected", path: "/tmp/reactivated-stale-auth.json")
    store.selectAccount(selected, for: .codex)
    let gate = UsageNotificationQueueGate()
    store.quotaNotificationTask = Task { await gate.wait() }

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    await gate.release()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.isEmpty)

    store.applySuccessfulFetch(
      fetchResult(accountName: selected.displayName),
      provider: .codex,
      account: selected
    )
    await store.waitForPendingQuotaNotifications()
    #expect(center.attemptedRequests.count == 1)
  }

  @Test func automaticReenableOrdersFreshScopeAfterTheNilScopeDrain() async throws {
    let discovered = account(name: "Matched", path: "/tmp/reactivated-automatic-auth.json")
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0, 0), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
    let harness = try await makeStore(
      "provider-reactivation-automatic",
      providers: [descriptor],
      discovery: StaticAccountDiscovery(accounts: [.codex: [discovered]])
    )
    let store = harness.store
    let center = harness.center
    await store.reloadAccounts()
    let gate = UsageNotificationQueueGate()
    store.quotaNotificationTask = Task { await gate.wait() }

    store.setProviderEnabled(.codex, enabled: false)
    store.setProviderEnabled(.codex, enabled: true)
    store.applySuccessfulFetch(
      fetchResult(accountName: discovered.displayName),
      provider: .codex,
      account: nil
    )
    await gate.release()
    await store.waitForPendingQuotaNotifications()

    #expect(center.attemptedRequests.count == 1)
    #expect(center.attemptedRequests.first?.key.logicalAccountID == discovered.id)
  }
}
