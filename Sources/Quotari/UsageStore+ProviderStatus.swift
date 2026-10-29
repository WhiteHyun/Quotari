import AppKit
import QuotariCore

extension UsageStore {
  /// Status pages are polled in the background so an outage can't pass for a
  /// quota or sign-in problem.
  static let providerStatusPollInterval: Duration = .seconds(5 * 60)

  /// Polls until the store goes away. The loop never keeps the store alive.
  func startProviderStatusMonitor() {
    Task { [weak self] in
      while !Task.isCancelled {
        guard await self?.pollProviderStatus() != nil else { return }
        do {
          try await Task.sleep(for: Self.providerStatusPollInterval)
        } catch {
          return
        }
      }
    }
  }

  func pollProviderStatus() async {
    for event in await providerStatus.poll(enabledProviderDescriptors.map(\.id)) {
      await quotaNotifications.deliverOutageAlert(event)
    }
  }

  var hasActiveProviderOutage: Bool {
    enabledProviderDescriptors.contains { providerStatus.outage(for: $0.id) != nil }
  }
}
