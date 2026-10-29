import Foundation
import QuotariCore

/// Delivers reset-credit expiry reminders through the notification center and
/// persists the ones it accepted. Owned by `QuotaNotificationController`.
@MainActor
final class ResetCreditReminderScheduler {
  static let persistenceKey = "quotaNotification.resetCreditReminders.v1"

  private let center: any QuotaNotificationCenterTransport
  private let defaults: UserDefaults
  private var policy: ResetCreditReminderPolicy

  init(center: any QuotaNotificationCenterTransport, defaults: UserDefaults) {
    self.center = center
    self.defaults = defaults
    policy = ResetCreditReminderPolicy(
      ledger: QuotaNotificationController.load(
        ResetCreditReminderLedger.self,
        key: Self.persistenceKey,
        defaults: defaults
      ) ?? ResetCreditReminderLedger()
    )
  }

  struct Outcome {
    var result = QuotaNotificationProcessingResult()
    var latestError: String?
  }

  func process(
    snapshot: UsageSnapshot,
    logicalAccountID: String,
    now: Date,
    isEnabled: @MainActor () -> Bool,
    isCurrent: @MainActor @Sendable () -> Bool
  ) async -> Outcome {
    var outcome = Outcome()
    let evaluation = policy.evaluate(
      expiries: snapshot.resetCreditExpiries,
      provider: snapshot.provider,
      logicalAccountID: logicalAccountID,
      isEnabled: isEnabled(),
      now: now
    )
    persist()
    if !evaluation.cancellationRequestIDs.isEmpty {
      center.removePendingRequests(withIdentifiers: evaluation.cancellationRequestIDs)
      outcome.result.cancelledRequestIDs.append(contentsOf: evaluation.cancellationRequestIDs)
    }

    for reminder in evaluation.reminders {
      guard isCurrent() else { break }
      do {
        try await center.addResetCreditReminder(reminder)
        // Reminders may have been turned off while the center was adding this one.
        guard isCurrent(), isEnabled() else {
          center.removeRequests(withIdentifiers: [reminder.requestID])
          outcome.result.cancelledRequestIDs.append(reminder.requestID)
          continue
        }
        policy.recordSuccess(for: reminder)
        persist()
        outcome.result.acceptedRequestIDs.append(reminder.requestID)
      } catch {
        outcome.latestError = error.localizedDescription
        outcome.result.failedRequestIDs.append(reminder.requestID)
      }
    }
    return outcome
  }

  @discardableResult
  func cancel(
    now: Date = Date(),
    where shouldCancel: (UsageProvider, String) -> Bool
  ) -> [String] {
    let identifiers = policy.clearReminders(now: now, where: shouldCancel)
    persist()
    if !identifiers.isEmpty {
      center.removePendingRequests(withIdentifiers: identifiers)
    }
    return identifiers
  }

  private func persist() {
    QuotaNotificationController.save(policy.ledger, key: Self.persistenceKey, defaults: defaults)
  }
}
