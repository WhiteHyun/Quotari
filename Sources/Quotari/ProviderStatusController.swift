import Observation
import QuotariCore

@MainActor
@Observable
final class ProviderStatusController {
  private(set) var statuses: [UsageProvider: ProviderServiceStatus]
  private(set) var failedProviders: Set<UsageProvider>
  private(set) var refreshingProviders = Set<UsageProvider>()

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

  /// Loads only the provider the user asked to inspect. Status checks are not
  /// started when the menu opens, keeping service health separate from quota refreshes.
  func refresh(_ provider: UsageProvider, forceRefresh: Bool = false) async {
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
      guard !Task.isCancelled, refreshGenerations[provider] == generation else { return }
      statuses[provider] = status
      failedProviders.remove(provider)
    } catch is CancellationError {
      return
    } catch {
      guard refreshGenerations[provider] == generation else { return }
      failedProviders.insert(provider)
    }
  }
}
