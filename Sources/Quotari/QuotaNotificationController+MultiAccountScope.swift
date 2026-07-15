import QuotariCore

extension QuotaNotificationController {
  func addActiveLogicalAccountID(
    _ logicalAccountID: String,
    for provider: UsageProvider
  ) {
    guard !logicalAccountID.isEmpty else { return }
    scopedProviders.insert(provider)
    activeLogicalAccountIDs[provider, default: []].insert(logicalAccountID)
  }

  func removeActiveLogicalAccountID(
    _ logicalAccountID: String,
    for provider: UsageProvider
  ) {
    var logicalAccountIDs = activeLogicalAccountIDs[provider] ?? []
    logicalAccountIDs.remove(logicalAccountID)
    _ = setActiveLogicalAccountIDs(logicalAccountIDs, for: provider)
  }
}
