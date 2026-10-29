import Foundation
import QuotariCore

/// Records every fresh insights summary into the daily archive and fills days
/// whose logs were deleted back in.
@MainActor
final class DailyUsageArchiveKeeper {
  var store = DailyUsageArchiveStore()
  private var loaded: DailyUsageArchive?

  func keep(_ summary: UsageInsightsSummary) -> UsageInsightsSummary {
    var archive = loaded ?? store.load()
    if archive.record(summary) {
      try? store.save(archive)
    }
    loaded = archive
    return archive.restoring(summary)
  }

  func days(for scope: UsageInsightsScopeKey) -> [DailyUsageInsight] {
    let archive = loaded ?? store.load()
    loaded = archive
    return archive.days(for: scope)
  }
}

extension UsageStore {
  /// Every archived day for the provider's current insights scope, ready to
  /// export.
  func usageExport(for provider: UsageProvider) -> UsageExport? {
    guard let summary = usageInsightsState(for: provider).summary else { return nil }
    return UsageExport(
      provider: provider,
      source: summary.source,
      accountScope: summary.accountScope,
      days: dailyUsageArchive.days(for: summary.scopeKey)
    )
  }
}
