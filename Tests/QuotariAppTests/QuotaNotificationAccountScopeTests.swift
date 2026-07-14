import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension QuotaNotificationControllerTests {
  @Test func activeAccountChangeCancelsOtherResetsButKeepsThresholdHistory() async throws {
    let defaults = try makeDefaults("account-scope")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    controller.setActiveLogicalAccountID("account-a", for: .codex)
    let result = await controller.process(
      snapshot: snapshot(
        sessionUsed: 80,
        weeklyUsed: 20,
        resetAt: now.addingTimeInterval(86400)
      ),
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now
    )
    let resetID = try #require(
      center.attemptedRequests.first(where: { $0.kind == .weeklyReset })?.requestID
    )
    let warningKey = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: "account-a",
      window: .session
    )
    let resetKey = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: "account-a",
      window: .weekly
    )
    #expect(result.acceptedRequestIDs.count == 2)

    let cancelled = controller.setActiveLogicalAccountID("account-b", for: .codex)

    #expect(cancelled == [resetID])
    #expect(center.pendingScheduledIDs.isEmpty)
    #expect(controller.ledger.windows[resetKey]?.scheduledReset == nil)
    #expect(controller.ledger.windows[warningKey]?.deliveredThresholds == [.warning])
    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    #expect(relaunched.ledger.windows[resetKey]?.scheduledReset == nil)
    #expect(relaunched.ledger.windows[warningKey]?.deliveredThresholds == [.warning])
  }

  @Test func accountChangeDiscardsAnInFlightResetAddFromTheOldAccount() async throws {
    let defaults = try makeDefaults("in-flight-account-scope")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    controller.setActiveLogicalAccountID("account-a", for: .codex)
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

    controller.setActiveLogicalAccountID("account-b", for: .codex)
    center.resumeAdds()
    let result = await processing.value
    let requestID = try #require(center.attemptedRequests.first?.requestID)

    #expect(result.acceptedRequestIDs.isEmpty)
    #expect(result.cancelledRequestIDs == [requestID])
    #expect(center.pendingScheduledIDs.isEmpty)
    #expect(controller.ledger.scheduledID(provider: .codex) == nil)
  }
}
