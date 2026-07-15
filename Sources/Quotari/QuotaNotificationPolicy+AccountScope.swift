import QuotariCore

extension QuotaNotificationPolicy {
  /// Clears only reset schedules outside the provider's active account scope.
  /// Threshold delivery history remains attached to each logical account so a
  /// later return to that account does not redeliver an already-seen warning.
  mutating func clearScheduledResets(
    for provider: UsageProvider,
    keeping logicalAccountID: String?
  ) -> [String] {
    clearScheduledResets(
      for: provider,
      keeping: Set([logicalAccountID].compactMap(\.self))
    )
  }

  /// Multi-account monitoring keeps reset reminders for every account still
  /// in scope while removing schedules for accounts the user stopped watching.
  mutating func clearScheduledResets(
    for provider: UsageProvider,
    keeping logicalAccountIDs: Set<String>
  ) -> [String] {
    var requestIDs: [String] = []
    for key in Array(ledger.windows.keys) where key.provider == provider {
      guard !logicalAccountIDs.contains(key.logicalAccountID),
            var state = ledger.windows[key],
            let requestID = state.scheduledReset?.requestID
      else { continue }
      requestIDs.append(requestID)
      state.scheduledReset = nil
      ledger.windows[key] = state
    }
    return Array(Set(requestIDs)).sorted()
  }
}
