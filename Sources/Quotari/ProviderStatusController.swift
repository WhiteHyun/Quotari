import Observation
import QuotariCore

@MainActor
@Observable
final class ProviderStatusController {
  private(set) var statuses: [UsageProvider: ProviderServiceStatus]
  private(set) var failedProviders: Set<UsageProvider>
  private(set) var refreshingProviders = Set<UsageProvider>()
  private(set) var outageTracker = ProviderOutageTracker()

  private let service: any ProviderStatusServing
  private var refreshGenerations: [UsageProvider: UInt] = [:]

  init(
    service: any ProviderStatusServing = ProviderStatusService.shared,
    initialStatuses: [UsageProvider: ProviderServiceStatus] = [:],
    failedProviders: Set<UsageProvider> = []
  ) {
    self.service = service
    statuses = initialStatuses
    self.failedProviders = failedProviders
  }

  func status(for provider: UsageProvider) -> ProviderServiceStatus? {
    statuses[provider]
  }

  func isRefreshing(_ provider: UsageProvider) -> Bool {
    refreshingProviders.contains(provider)
  }

  func outage(for provider: UsageProvider) -> ProviderOutage? {
    outageTracker.outage(for: provider)
  }

  /// Loads only the provider the user asked to inspect. Status checks are not
  /// started when the menu opens, keeping service health separate from quota refreshes.
  @discardableResult
  func refresh(_ provider: UsageProvider, forceRefresh: Bool = false) async -> ProviderOutageEvent? {
    let generation = (refreshGenerations[provider] ?? 0) &+ 1
    refreshGenerations[provider] = generation
    refreshingProviders.insert(provider)

    defer {
      if refreshGenerations[provider] == generation {
        refreshingProviders.remove(provider)
      }
    }

    do {
      let status = try await service.status(for: provider, forceRefresh: forceRefresh)
      guard !Task.isCancelled, refreshGenerations[provider] == generation else { return nil }
      statuses[provider] = status
      failedProviders.remove(provider)
      return outageTracker.update(with: status)
    } catch is CancellationError {
      return nil
    } catch {
      guard refreshGenerations[provider] == generation else { return nil }
      failedProviders.insert(provider)
      return nil
    }
  }

  /// Refreshes the watched providers once. Providers that stop being watched
  /// drop their outage without a resolution event.
  func poll(_ watched: [UsageProvider]) async -> [ProviderOutageEvent] {
    for provider in UsageProvider.allCases where !watched.contains(provider) {
      outageTracker.forget(provider)
    }
    var events: [ProviderOutageEvent] = []
    for provider in watched {
      if let event = await refresh(provider, forceRefresh: true) {
        events.append(event)
      }
    }
    return events
  }
}
