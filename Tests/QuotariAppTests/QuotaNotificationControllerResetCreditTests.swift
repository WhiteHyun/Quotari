import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

extension QuotaNotificationControllerTests {
  @Test func scheduledResetCreditReminderPersistsAndIsNotRepeated() async throws {
    let defaults = try makeDefaults("reset-credit-schedule")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)

    _ = await controller.process(
      snapshot: creditSnapshot(expiringIn: 72 * 3600), logicalAccountID: "work", sourceKind: nil, now: now
    )

    #expect(center.attemptedReminders.map(\.requestID) == ["quotari.reset-credit.codex.credit-1"])
    #expect(center.attemptedReminders.map(\.deliverAt) == [now.addingTimeInterval(48 * 3600)])

    let relaunched = QuotaNotificationController(center: center, defaults: defaults)
    _ = await relaunched.process(
      snapshot: creditSnapshot(expiringIn: 72 * 3600), logicalAccountID: "work", sourceKind: nil, now: now
    )
    #expect(center.attemptedReminders.count == 1)
  }

  @Test func turningResetCreditRemindersOffCancelsThePendingOne() async throws {
    let defaults = try makeDefaults("reset-credit-toggle")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    _ = await controller.process(
      snapshot: creditSnapshot(expiringIn: 72 * 3600), logicalAccountID: "work", sourceKind: nil, now: now
    )

    controller.remindsBeforeResetCreditsExpire = false

    #expect(center.removedRequestIDs.last == ["quotari.reset-credit.codex.credit-1"])
    _ = await controller.process(
      snapshot: creditSnapshot(expiringIn: 72 * 3600), logicalAccountID: "work", sourceKind: nil, now: now
    )
    #expect(center.attemptedReminders.count == 1)
  }

  @Test func turningNotificationsOffCancelsPendingResetCreditReminders() async throws {
    let defaults = try makeDefaults("reset-credit-notifications-off")
    let center = QuotaNotificationCenterStub(status: .authorized)
    let controller = QuotaNotificationController(center: center, defaults: defaults)
    _ = await controller.setNotificationsEnabled(true)
    _ = await controller.process(
      snapshot: creditSnapshot(expiringIn: 72 * 3600), logicalAccountID: "work", sourceKind: nil, now: now
    )

    _ = await controller.setNotificationsEnabled(false)

    #expect(center.removedRequestIDs.flatMap(\.self).contains("quotari.reset-credit.codex.credit-1"))
  }

  private func creditSnapshot(expiringIn interval: TimeInterval) -> UsageSnapshot {
    UsageSnapshot(
      provider: .codex,
      availableResetCredits: 1,
      resetCreditExpiries: [ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(interval))],
      updatedAt: now
    )
  }
}
