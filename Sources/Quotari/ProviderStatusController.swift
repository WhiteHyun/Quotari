import Observation
import QuotariCore

@MainActor
@Observable
final class ProviderStatusController {
  private(set) var statuses: [UsageProvider: ProviderServiceStatus]
  private(set) var failedProviders = Set<UsageProvider>()
  private(set) var isRefreshing = false

  private let service: any ProviderStatusServing
  private var refreshGeneration: UInt = 0

  init(
    service: any ProviderStatusServing = ProviderStatusService.shared,
    initialStatuses: [UsageProvider: ProviderServiceStatus] = [:]
  ) {
    self.service = service
    statuses = initialStatuses
  }

  func refresh(providers: [UsageProvider], forceRefresh: Bool = false) async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    let providers = Array(Set(providers))
    guard !providers.isEmpty else {
      statuses = [:]
      failedProviders = []
      isRefreshing = false
      return
    }

    isRefreshing = true
    defer {
      if generation == refreshGeneration {
        isRefreshing = false
      }
    }
    let results = await Self.loadStatuses(
      providers: providers,
      service: service,
      forceRefresh: forceRefresh
    )

    guard !Task.isCancelled, generation == refreshGeneration else { return }
    apply(results, enabledProviders: Set(providers))
  }

  private nonisolated static func loadStatuses(
    providers: [UsageProvider],
    service: any ProviderStatusServing,
    forceRefresh: Bool
  ) async -> [ProviderStatusResult] {
    await withTaskGroup(of: ProviderStatusResult.self) { group in
      for provider in providers {
        group.addTask {
          do {
            let status = try await service.status(for: provider, forceRefresh: forceRefresh)
            return .success(provider, status)
          } catch is CancellationError {
            return .cancelled(provider)
          } catch {
            return .failure(provider)
          }
        }
      }

      var results: [ProviderStatusResult] = []
      for await result in group {
        results.append(result)
      }
      return results
    }
  }

  private func apply(
    _ results: [ProviderStatusResult],
    enabledProviders: Set<UsageProvider>
  ) {
    statuses = statuses.filter { enabledProviders.contains($0.key) }
    failedProviders.formIntersection(enabledProviders)
    for result in results {
      switch result {
      case let .success(provider, status):
        statuses[provider] = status
        failedProviders.remove(provider)
      case let .failure(provider):
        failedProviders.insert(provider)
      case .cancelled:
        break
      }
    }
  }
}

private enum ProviderStatusResult: Sendable {
  case success(UsageProvider, ProviderServiceStatus)
  case failure(UsageProvider)
  case cancelled(UsageProvider)
}
