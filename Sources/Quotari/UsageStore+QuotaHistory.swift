import Foundation
import QuotariCore

extension UsageStore {
  var quotaHistory: QuotaHistory {
    storedQuotaHistory ?? QuotaHistory()
  }

  /// Stores the dashboard account's live session and weekly readings.
  func recordQuotaHistory(_ snapshot: UsageSnapshot, provider: UsageProvider) {
    var history = storedQuotaHistory ?? quotaHistoryStore.load()
    for window in [snapshot.primary, snapshot.secondary].compactMap(\.self) {
      history.record(
        QuotaObservation(usedPercent: window.usedPercent, resetsAt: window.resetsAt, observedAt: snapshot.updatedAt),
        for: quotaSeriesKey(provider: provider, window: window.kind)
      )
    }
    storedQuotaHistory = history
    try? quotaHistoryStore.save(history)
  }

  func quotaHistoryReadings(for provider: UsageProvider, window: RateWindow) -> [QuotaObservation] {
    quotaHistory.currentCycle(for: quotaSeriesKey(provider: provider, window: window.kind), resetsAt: window.resetsAt)
  }

  /// Pace from the window average, with run-out and headroom taken from the
  /// recent burn rate when history covers enough of the current cycle.
  func quotaPace(for provider: UsageProvider, window: RateWindow, now: Date) -> UsagePace? {
    let (lookback, minimumSpan): (TimeInterval, TimeInterval) = window.kind == .session
      ? (60 * 60, 15 * 60)
      : (24 * 60 * 60, 3 * 60 * 60)
    let recentRate = QuotaBurndown.recentBurnRate(
      quotaHistoryReadings(for: provider, window: window),
      now: now,
      lookback: lookback,
      minimumSpan: minimumSpan
    )
    return UsagePace.compute(
      window: window,
      now: now,
      recentBurnRate: recentRate,
      countsWeekdaysOnly: paceCountsWeekdaysOnly
    )
  }

  private func quotaSeriesKey(provider: UsageProvider, window: UsageWindowKind) -> QuotaSeriesKey {
    let accountID = activeAccount(for: provider).map(logicalMonitoringAccountID) ?? "automatic"
    return QuotaSeriesKey(provider: provider, accountID: accountID, window: window)
  }
}
