import Foundation
import QuotariCore

/// A notification that one rate-limit reset credit expires soon.
struct ResetCreditReminder: Equatable, Sendable {
  var requestID: String
  var provider: UsageProvider
  var logicalAccountID: String
  var expiresAt: Date
  /// Nil delivers immediately.
  var deliverAt: Date?
}

/// Reminders the notification center has accepted, keyed by request ID.
struct ResetCreditReminderLedger: Codable, Equatable, Sendable {
  struct Record: Codable, Equatable, Sendable {
    var provider: UsageProvider
    var logicalAccountID: String
    var expiresAt: Date
    var deliverAt: Date?
  }

  var reminders: [String: Record] = [:]
}

struct ResetCreditReminderEvaluation: Equatable, Sendable {
  var reminders: [ResetCreditReminder] = []
  var cancellationRequestIDs: [String] = []
}

/// Pure reminder policy for expiring reset credits. Quotari only reminds; it
/// never redeems a credit (ADR 0001).
struct ResetCreditReminderPolicy: Equatable, Sendable {
  static let leadTime: TimeInterval = 24 * 3600

  var ledger = ResetCreditReminderLedger()

  mutating func evaluate(
    expiries: [ResetCreditExpiry]?,
    provider: UsageProvider,
    logicalAccountID: String,
    isEnabled: Bool,
    now: Date
  ) -> ResetCreditReminderEvaluation {
    var evaluation = ResetCreditReminderEvaluation()
    guard let expiries else { return evaluation }
    // Disabled reminders behave as if no credit needed one.
    let remindable = isEnabled ? expiries : []
    let currentIDs = Set(remindable.map { Self.requestID(provider: provider, creditID: $0.id) })
    for (requestID, record) in ledger.reminders
      where record.provider == provider
      && record.logicalAccountID == logicalAccountID
      && !currentIDs.contains(requestID) {
      if let deliverAt = record.deliverAt, deliverAt > now {
        evaluation.cancellationRequestIDs.append(requestID)
      }
      ledger.reminders[requestID] = nil
    }
    evaluation.cancellationRequestIDs.sort()

    for expiry in remindable {
      let requestID = Self.requestID(provider: provider, creditID: expiry.id)
      guard expiry.expiresAt > now, ledger.reminders[requestID] == nil else { continue }
      let reminderDate = expiry.expiresAt.addingTimeInterval(-Self.leadTime)
      evaluation.reminders.append(ResetCreditReminder(
        requestID: requestID,
        provider: provider,
        logicalAccountID: logicalAccountID,
        expiresAt: expiry.expiresAt,
        deliverAt: reminderDate > now ? reminderDate : nil
      ))
    }
    return evaluation
  }

  /// Drops every reminder whose provider and account match, returning the IDs
  /// still pending in the notification center so the caller can remove them.
  mutating func clearReminders(
    now: Date,
    where shouldClear: (UsageProvider, String) -> Bool
  ) -> [String] {
    var pending: [String] = []
    for (requestID, record) in ledger.reminders
      where shouldClear(record.provider, record.logicalAccountID) {
      if let deliverAt = record.deliverAt, deliverAt > now {
        pending.append(requestID)
      }
      ledger.reminders[requestID] = nil
    }
    return pending.sorted()
  }

  static func requestID(provider: UsageProvider, creditID: String) -> String {
    "quotari.reset-credit.\(provider.rawValue).\(creditID)"
  }

  /// Call only after the notification center accepts the reminder.
  mutating func recordSuccess(for reminder: ResetCreditReminder) {
    ledger.reminders[reminder.requestID] = ResetCreditReminderLedger.Record(
      provider: reminder.provider,
      logicalAccountID: reminder.logicalAccountID,
      expiresAt: reminder.expiresAt,
      deliverAt: reminder.deliverAt
    )
  }
}
