import Foundation
@testable import Quotari
import QuotariCore
import Testing

struct ResetCreditReminderPolicyTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private let hour: TimeInterval = 3600

  @Test func schedulesAReminderADayBeforeExpiry() {
    var policy = ResetCreditReminderPolicy()
    let expiry = ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(72 * hour))

    let evaluation = policy.evaluate(
      expiries: [expiry], provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    )

    #expect(evaluation.reminders == [ResetCreditReminder(
      requestID: "quotari.reset-credit.codex.credit-1",
      provider: .codex,
      logicalAccountID: "work",
      expiresAt: expiry.expiresAt,
      deliverAt: now.addingTimeInterval(48 * hour)
    )])
    #expect(evaluation.cancellationRequestIDs.isEmpty)
  }

  @Test func remindsImmediatelyWhenLessThanADayIsLeft() {
    var policy = ResetCreditReminderPolicy()

    let evaluation = policy.evaluate(
      expiries: [ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(6 * hour))],
      provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    )

    #expect(evaluation.reminders.map(\.deliverAt) == [nil])
  }

  @Test func acceptedRemindersAreNotRepeated() {
    var policy = ResetCreditReminderPolicy()
    let expiries = [ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(6 * hour))]
    for reminder in policy.evaluate(
      expiries: expiries, provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    ).reminders {
      policy.recordSuccess(for: reminder)
    }

    let again = policy.evaluate(
      expiries: expiries, provider: .codex, logicalAccountID: "work", isEnabled: true,
      now: now.addingTimeInterval(hour)
    )

    #expect(again.reminders.isEmpty)
  }

  @Test func redeemedCreditCancelsItsPendingReminder() {
    var policy = ResetCreditReminderPolicy()
    let expiries = [ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(72 * hour))]
    for reminder in policy.evaluate(
      expiries: expiries, provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    ).reminders {
      policy.recordSuccess(for: reminder)
    }

    let afterRedeeming = policy.evaluate(
      expiries: [], provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    )

    #expect(afterRedeeming.cancellationRequestIDs == ["quotari.reset-credit.codex.credit-1"])
    #expect(policy.ledger.reminders.isEmpty)
  }

  @Test func turningRemindersOffCancelsPendingOnesAndSchedulesNothing() {
    var policy = ResetCreditReminderPolicy()
    let expiries = [
      ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(72 * hour)),
      ResetCreditExpiry(id: "credit-2", expiresAt: now.addingTimeInterval(96 * hour)),
    ]
    if let first = policy.evaluate(
      expiries: expiries, provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    ).reminders.first {
      policy.recordSuccess(for: first)
    }

    let disabled = policy.evaluate(
      expiries: expiries, provider: .codex, logicalAccountID: "work", isEnabled: false, now: now
    )

    #expect(disabled.reminders.isEmpty)
    #expect(disabled.cancellationRequestIDs == ["quotari.reset-credit.codex.credit-1"])
    #expect(policy.ledger.reminders.isEmpty)
  }

  @Test func clearingRemindersCancelsOnlyMatchingPendingOnes() {
    var policy = ResetCreditReminderPolicy()
    for (account, hours) in [("work", 72.0), ("personal", 72.0), ("work-soon", 6.0)] {
      for reminder in policy.evaluate(
        expiries: [ResetCreditExpiry(id: "\(account)-credit", expiresAt: now.addingTimeInterval(hours * hour))],
        provider: .codex, logicalAccountID: account, isEnabled: true, now: now
      ).reminders {
        policy.recordSuccess(for: reminder)
      }
    }

    let cancelled = policy.clearReminders(now: now) { _, account in account.hasPrefix("work") }

    // The already-delivered reminder has nothing pending to cancel, but its record goes too.
    #expect(cancelled == ["quotari.reset-credit.codex.work-credit"])
    #expect(Array(policy.ledger.reminders.keys) == ["quotari.reset-credit.codex.personal-credit"])
  }

  @Test func expiredCreditsGetNoReminder() {
    var policy = ResetCreditReminderPolicy()

    let evaluation = policy.evaluate(
      expiries: [ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(-hour))],
      provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    )

    #expect(evaluation.reminders.isEmpty)
  }

  @Test func unknownExpiriesLeaveRemindersUntouched() {
    var policy = ResetCreditReminderPolicy()
    for reminder in policy.evaluate(
      expiries: [ResetCreditExpiry(id: "credit-1", expiresAt: now.addingTimeInterval(72 * hour))],
      provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    ).reminders {
      policy.recordSuccess(for: reminder)
    }

    let unknown = policy.evaluate(
      expiries: nil, provider: .codex, logicalAccountID: "work", isEnabled: true, now: now
    )

    #expect(unknown == ResetCreditReminderEvaluation())
    #expect(policy.ledger.reminders.count == 1)
  }
}
