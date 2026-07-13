import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct QuotaNotificationControllerTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func authorizationDenialStaysDisabledAndALaterGrantCanEnable() async throws {
    let defaults = try makeDefaults("authorization")
    let center = QuotaNotificationCenterStub(status: .notDetermined)
    center.grantsAuthorization = false
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    let denied = await controller.setNotificationsEnabled(true)
    #expect(!denied)
    #expect(!controller.preferences.isEnabled)
    #expect(controller.authorizationStatus == .denied)
    #expect(controller.authorizationMessage != nil)
    #expect(center.authorizationRequestCount == 1)
    #expect(center.foregroundPresentationConfigured)
    center.status = .authorized
    let enabled = await controller.setNotificationsEnabled(true)
    #expect(enabled)
    #expect(controller.preferences.isEnabled)

    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    #expect(relaunched.preferences.isEnabled)
  }

  @Test func successfulThresholdDeliveryPersistsAndDeduplicatesAcrossRelaunch() async throws {
    let defaults = try makeDefaults("threshold-dedup")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let resetAt = now.addingTimeInterval(3600)
    let first = await controller.process(
      snapshot: snapshot(sessionUsed: 80, resetAt: resetAt),
      logicalAccountID: "account-a",
      sourceKind: .oauth,
      now: now
    )
    #expect(first.acceptedRequestIDs.count == 1)
    #expect(center.attemptedRequests.first?.kind == .warning)
    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    let duplicate = await relaunched.process(
      snapshot: snapshot(sessionUsed: 80, resetAt: resetAt),
      logicalAccountID: "account-a",
      sourceKind: .oauth,
      now: now
    )
    #expect(duplicate.acceptedRequestIDs.isEmpty)
    #expect(center.attemptedRequests.count == 1)
  }

  @Test func concurrentProcessesSerializeBeforeEvaluatingTheLedger() async throws {
    let defaults = try makeDefaults("concurrent-dedup")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    center.suspendAdds = true
    let input = snapshot(sessionUsed: 80, resetAt: now.addingTimeInterval(3600))

    let first = Task {
      await controller.process(snapshot: input, logicalAccountID: "account-a", sourceKind: .oauth, now: now)
    }
    await center.waitForSuspendedAdd()
    let second = Task {
      await controller.process(snapshot: input, logicalAccountID: "account-a", sourceKind: .oauth, now: now)
    }
    await Task.yield()
    #expect(center.suspendedAddCount == 1)
    center.resumeAdds()
    let results = await [first.value, second.value]
    #expect(results.flatMap(\.acceptedRequestIDs).count == 1)
    #expect(center.attemptedRequests.count == 1)
  }

  @Test func failedDeliveryRetriesTheSameRequestAndRecordsOnlySuccess() async throws {
    let defaults = try makeDefaults("delivery-retry")
    let center = QuotaNotificationCenterStub(status: .authorized)
    center.failuresRemaining = 1
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let input = snapshot(sessionUsed: 96, resetAt: now.addingTimeInterval(3600))

    let failed = await controller.process(
      snapshot: input,
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    let key = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: "account-a",
      window: .session
    )
    #expect(failed.failedRequestIDs.count == 1)
    #expect(controller.ledger.windows[key]?.deliveredThresholds == [])
    let retried = await controller.process(
      snapshot: input,
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    #expect(retried.acceptedRequestIDs == failed.failedRequestIDs)
    #expect(center.attemptedRequests.map(\.requestID).count == 2)
    #expect(Set(center.attemptedRequests.map(\.requestID)).count == 1)
    #expect(controller.ledger.windows[key]?.deliveredThresholds == [.warning, .critical])
    #expect(controller.lastError == nil)
  }

  @Test func weeklyResetIsScheduledAndAChangedDateUpdatesIt() async throws {
    let defaults = try makeDefaults("weekly-replacement")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let firstReset = now.addingTimeInterval(86400)
    let first = await controller.process(
      snapshot: snapshot(weeklyUsed: 20, resetAt: firstReset),
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    let firstID = try #require(first.acceptedRequestIDs.first)
    #expect(center.pendingScheduledIDs == [firstID])
    let correctedReset = firstReset.addingTimeInterval(
      QuotaNotificationPolicy.resetDateTolerance + 60
    )
    let replacement = await controller.process(
      snapshot: snapshot(weeklyUsed: 20, resetAt: correctedReset),
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    #expect(replacement.cancelledRequestIDs.isEmpty)
    #expect(replacement.acceptedRequestIDs == [firstID])
    #expect(center.attemptedRequests.last?.deliverAt == correctedReset)
    #expect(center.pendingScheduledIDs == [firstID])
  }
}

extension QuotaNotificationControllerTests {
  @Test func preferencesPersistAndInvalidThresholdsAreNormalized() async throws {
    let defaults = try makeDefaults("preferences")
    let invalid = QuotaNotificationPreferences(
      isEnabled: false,
      warningThreshold: 120,
      criticalThreshold: -5
    )
    try defaults.set(
      JSONEncoder().encode(invalid),
      forKey: "quotaNotification.preferences.v1"
    )
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    #expect(controller.preferences.warningThreshold == 99)
    #expect(controller.preferences.criticalThreshold == 100)
    #expect(!controller.updateThresholds(warning: 0, critical: 90))
    #expect(controller.updateThresholds(warning: 70, critical: 90))
    controller.setProvider(.claude, enabled: false)
    _ = await controller.setNotificationsEnabled(true)
    #expect(!controller.updateThresholds(warning: 95, critical: 90))
    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    #expect(relaunched.preferences.warningThreshold == 70)
    #expect(relaunched.preferences.criticalThreshold == 90)
    #expect(relaunched.preferences.enabledProviders == [.codex])
    #expect(relaunched.preferences.isEnabled)
  }

  @Test func providerAndGlobalDisableCancelPersistedSchedulesWithoutASnapshot() async throws {
    let defaults = try makeDefaults("disable")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let resetAt = now.addingTimeInterval(86400)
    _ = await controller.process(
      snapshot: snapshot(provider: .codex, weeklyUsed: 10, resetAt: resetAt),
      logicalAccountID: "codex-account",
      sourceKind: .api,
      now: now
    )
    _ = await controller.process(
      snapshot: snapshot(provider: .claude, weeklyUsed: 10, resetAt: resetAt),
      logicalAccountID: "claude-account",
      sourceKind: .oauth,
      now: now
    )
    #expect(center.pendingScheduledIDs.count == 2)
    controller.setProvider(.codex, enabled: false)
    #expect(center.pendingScheduledIDs.count == 1)
    #expect(controller.ledger.scheduledID(provider: .codex) == nil)
    #expect(controller.ledger.scheduledID(provider: .claude) != nil)
    _ = await controller.setNotificationsEnabled(false)
    #expect(center.pendingScheduledIDs.isEmpty)
    #expect(controller.ledger.scheduledID(provider: .claude) == nil)
    #expect(!controller.preferences.isEnabled)
    _ = await controller.setNotificationsEnabled(true)
    _ = await controller.process(
      snapshot: snapshot(provider: .claude, weeklyUsed: 10, resetAt: resetAt),
      logicalAccountID: "claude-account",
      sourceKind: .oauth,
      now: now
    )
    var disabledPreferences = controller.preferences
    disabledPreferences.isEnabled = false
    try defaults.set(JSONEncoder().encode(disabledPreferences), forKey: "quotaNotification.preferences.v1")
    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    _ = await relaunched.refreshAuthorizationStatus()
    #expect(center.pendingScheduledIDs.isEmpty)
    #expect(relaunched.ledger.scheduledID(provider: .claude) == nil)
  }

  @Test(arguments: DisableMode.allCases)
  func anInFlightScheduledAddIsDiscardedWhenDisabled(_ mode: DisableMode) async throws {
    let defaults = try makeDefaults("in-flight-\(mode)")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    center.suspendAdds = true
    let processing = Task {
      await controller.process(
        snapshot: snapshot(weeklyUsed: 10, resetAt: now.addingTimeInterval(86400)),
        logicalAccountID: "account-a",
        sourceKind: .api,
        now: now
      )
    }
    await center.waitForSuspendedAdd()
    switch mode {
    case .global:
      _ = await controller.setNotificationsEnabled(false)
    case .provider:
      controller.setProvider(.codex, enabled: false)
    }
    center.resumeAdds()
    let result = await processing.value
    let requestID = try #require(center.attemptedRequests.first?.requestID)
    #expect(result.acceptedRequestIDs.isEmpty)
    #expect(result.cancelledRequestIDs == [requestID])
    #expect(center.pendingScheduledIDs.isEmpty)
    #expect(controller.ledger.scheduledID(provider: .codex) == nil)
  }

  @Test func reconciliationPreservesAResetVisibleBeforeItsLedgerCommit() async throws {
    let defaults = try makeDefaults("in-flight-reconciliation")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    center.publishesScheduledBeforeSuspending = true
    center.suspendAdds = true

    let processing = Task {
      await controller.process(
        snapshot: snapshot(weeklyUsed: 10, resetAt: now.addingTimeInterval(86400)),
        logicalAccountID: "account-a",
        sourceKind: .api,
        now: now
      )
    }
    await center.waitForSuspendedAdd()
    let requestID = try #require(center.attemptedRequests.first?.requestID)
    #expect(center.pendingScheduledIDs == [requestID])

    _ = await controller.refreshAuthorizationStatus()
    #expect(center.pendingScheduledIDs == [requestID])

    center.resumeAdds()
    let result = await processing.value
    #expect(result.acceptedRequestIDs == [requestID])
    #expect(controller.ledger.scheduledID(provider: .codex) == requestID)
    #expect(center.pendingScheduledIDs == [requestID])
  }

  @Test func missingSystemScheduleIsReconciledAndRetriedAfterRelaunch() async throws {
    let defaults = try makeDefaults("pending-reconcile")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let input = snapshot(weeklyUsed: 10, resetAt: now.addingTimeInterval(86400))
    _ = await controller.process(
      snapshot: input,
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    center.pendingScheduledIDs.removeAll()
    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    let retry = await relaunched.process(
      snapshot: input,
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    #expect(retry.acceptedRequestIDs.count == 1)
    #expect(center.attemptedRequests.count == 2)
  }

  @Test func missingLogicalAccountIdentitySkipsNotificationEvaluation() async throws {
    let defaults = try makeDefaults("missing-identity")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    let input = snapshot(sessionUsed: 100, resetAt: now.addingTimeInterval(3600))
    _ = await controller.process(snapshot: input, logicalAccountID: nil, sourceKind: .api, now: now)
    _ = await controller.process(snapshot: input, logicalAccountID: "", sourceKind: .api, now: now)
    #expect(center.attemptedRequests.isEmpty)
    #expect(controller.ledger.windows.isEmpty)
  }
}

@MainActor
final class QuotaNotificationCenterStub: QuotaNotificationCenterTransport {
  var status: QuotaNotificationAuthorizationStatus
  var grantsAuthorization = true
  var authorizationRequestCount = 0
  var failuresRemaining = 0
  var attemptedRequests: [QuotaNotificationRequest] = []
  var pendingScheduledIDs: Set<String> = []
  var deliveredIDs: Set<String> = []
  var removedRequestIDs: [[String]] = []
  var foregroundPresentationConfigured = false
  var suspendAdds = false
  var publishesScheduledBeforeSuspending = false
  private var suspendedAdds: [CheckedContinuation<Void, Never>] = []

  var suspendedAddCount: Int {
    suspendedAdds.count
  }

  init(status: QuotaNotificationAuthorizationStatus) {
    self.status = status
  }

  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    status
  }

  func requestAuthorization() async throws -> Bool {
    authorizationRequestCount += 1
    status = grantsAuthorization ? .authorized : .denied
    return grantsAuthorization
  }

  func pendingScheduledRequestIdentifiers() async -> Set<String> {
    pendingScheduledIDs
  }

  func add(_ request: QuotaNotificationRequest) async throws {
    attemptedRequests.append(request)
    if request.kind == .weeklyReset, publishesScheduledBeforeSuspending {
      pendingScheduledIDs.insert(request.requestID)
    }
    if suspendAdds {
      await withCheckedContinuation { continuation in
        suspendedAdds.append(continuation)
      }
    }
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw DeliveryError()
    }
    if request.kind == .weeklyReset {
      pendingScheduledIDs.insert(request.requestID)
    } else {
      deliveredIDs.insert(request.requestID)
    }
  }

  func removePendingRequests(withIdentifiers identifiers: [String]) {
    removedRequestIDs.append(identifiers.sorted())
    pendingScheduledIDs.subtract(identifiers)
  }

  func removeRequests(withIdentifiers identifiers: [String]) {
    removePendingRequests(withIdentifiers: identifiers)
    deliveredIDs.subtract(identifiers)
  }

  func configureForegroundPresentation() {
    foregroundPresentationConfigured = true
  }

  func waitForSuspendedAdd() async {
    while suspendedAdds.isEmpty {
      await Task.yield()
    }
  }

  func resumeAdds() {
    suspendAdds = false
    let continuations = suspendedAdds
    suspendedAdds.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }
}

enum DisableMode: CaseIterable {
  case global
  case provider
}

private struct DeliveryError: LocalizedError {
  var errorDescription: String? {
    "delivery failed"
  }
}
