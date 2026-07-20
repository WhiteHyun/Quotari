import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ProviderStatusControllerTests {
  @Test func refreshPublishesSuccessesAndTracksUnavailableProviders() async {
    let codex = status(provider: .codex, state: .degradedPerformance)
    let service = ProviderStatusServiceStub(results: [
      .codex: .success(codex),
      .claude: .failure,
    ])
    let controller = ProviderStatusController(service: service)

    await controller.refresh(providers: [.codex, .claude])

    #expect(controller.statuses[.codex] == codex)
    #expect(controller.statuses[.claude] == nil)
    #expect(controller.failedProviders == [.claude])
    #expect(!controller.isRefreshing)
  }

  @Test func failedRefreshPreservesTheLastKnownStatus() async {
    let previous = status(provider: .claude, state: .operational)
    let service = ProviderStatusServiceStub(results: [
      .claude: .failure,
    ])
    let controller = ProviderStatusController(
      service: service,
      initialStatuses: [.claude: previous]
    )

    await controller.refresh(providers: [.claude], forceRefresh: true)

    #expect(controller.statuses[.claude] == previous)
    #expect(controller.failedProviders == [.claude])
  }

  @Test func newerProviderSetWinsOverAnOlderInFlightRefresh() async {
    let service = DelayedProviderStatusService()
    let controller = ProviderStatusController(service: service)

    let first = Task {
      await controller.refresh(providers: [.codex])
    }
    try? await Task.sleep(for: .milliseconds(10))
    await controller.refresh(providers: [.claude])
    await first.value

    #expect(controller.statuses[.codex] == nil)
    #expect(controller.statuses[.claude]?.state == .operational)
    #expect(!controller.isRefreshing)
  }

  private func status(
    provider: UsageProvider,
    state: ProviderServiceState
  ) -> ProviderServiceStatus {
    ProviderServiceStatus(
      provider: provider,
      state: state,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      statusPageURL: provider.statusPageURL
    )
  }
}

private enum StatusStubError: Error {
  case unavailable
}

private enum ProviderStatusStubResult: Sendable {
  case success(ProviderServiceStatus)
  case failure
}

private actor ProviderStatusServiceStub: ProviderStatusServing {
  let results: [UsageProvider: ProviderStatusStubResult]

  init(results: [UsageProvider: ProviderStatusStubResult]) {
    self.results = results
  }

  func status(
    for provider: UsageProvider,
    forceRefresh: Bool
  ) async throws -> ProviderServiceStatus {
    _ = forceRefresh
    switch results[provider] {
    case let .success(status): return status
    case .failure, nil: throw StatusStubError.unavailable
    }
  }
}

private struct DelayedProviderStatusService: ProviderStatusServing {
  func status(
    for provider: UsageProvider,
    forceRefresh: Bool
  ) async throws -> ProviderServiceStatus {
    _ = forceRefresh
    try await Task.sleep(for: provider == .codex ? .milliseconds(80) : .milliseconds(1))
    return ProviderServiceStatus(
      provider: provider,
      state: .operational,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      statusPageURL: provider.statusPageURL
    )
  }
}
