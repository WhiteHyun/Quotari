@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
extension QuotaNotificationControllerTests {
  @Test func anInFlightImmediateAddIsRetractedWhenItsGenerationInvalidates() async throws {
    let defaults = try makeDefaults("in-flight-immediate-generation")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    center.suspendAdds = true
    var isCurrent = true
    let input = snapshot(sessionUsed: 80, resetAt: now.addingTimeInterval(3600))
    let processing = Task {
      await controller.process(
        snapshot: input,
        logicalAccountID: "account-a",
        sourceKind: .api,
        now: now,
        isCurrent: { isCurrent }
      )
    }
    await center.waitForSuspendedAdd()

    isCurrent = false
    center.resumeAdds()
    let stale = await processing.value
    let requestID = try #require(center.attemptedRequests.first?.requestID)
    let key = QuotaNotificationWindowKey(
      provider: .codex,
      logicalAccountID: "account-a",
      window: .session
    )
    #expect(stale.acceptedRequestIDs.isEmpty)
    #expect(stale.cancelledRequestIDs == [requestID])
    #expect(center.deliveredIDs.isEmpty)
    #expect(controller.ledger.windows[key]?.deliveredThresholds == [])

    isCurrent = true
    let fresh = await controller.process(
      snapshot: input,
      logicalAccountID: "account-a",
      sourceKind: .api,
      now: now,
      isCurrent: { isCurrent }
    )
    #expect(fresh.acceptedRequestIDs == [requestID])
    #expect(center.deliveredIDs == [requestID])
    #expect(controller.ledger.windows[key]?.deliveredThresholds == [.warning])
  }
}
