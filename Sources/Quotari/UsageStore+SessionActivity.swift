import Foundation
import QuotariCore

extension UsageStore {
  func startSessionActivityMonitor() {
    sessionActivity.syncHooks()
    sessionActivity.onEvent = { [weak self] event in
      guard let notifications = self?.quotaNotifications else { return }
      Task { await notifications.deliverSessionActivityAlert(event) }
    }
    sessionActivity.startListening()
  }

  /// Keeps running-session counts current until cancelled, e.g. while the
  /// dashboard is open.
  func watchRunningSessions(every interval: Duration = .seconds(10)) async {
    while !Task.isCancelled {
      await sessionActivity.refreshRunningCounts(for: enabledProviderDescriptors.map(\.id))
      try? await Task.sleep(for: interval)
    }
  }
}
