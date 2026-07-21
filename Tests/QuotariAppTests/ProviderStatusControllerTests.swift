import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ProviderStatusControllerTests {
  @Test func statusChecksStayIdleUntilAProviderIsRequested() async {
    let service = RecordingProviderStatusService()
    let controller = ProviderStatusController(service: service)

    #expect(await service.requestedProviders.isEmpty)
    #expect(controller.statuses.isEmpty)
    #expect(controller.refreshingProviders.isEmpty)
  }

  @Test func refreshingOneProviderPreservesAnotherProvidersStatus() async {
    let codex = Self.status(provider: .codex, state: .degradedPerformance)
    let claude = Self.status(provider: .claude, state: .operational)
    let service = RecordingProviderStatusService(results: [
      .codex: .success(codex),
      .claude: .success(claude),
    ])
    let controller = ProviderStatusController(service: service)

    await controller.refresh(.codex)
    await controller.refresh(.claude)

    #expect(controller.statuses[.codex] == codex)
    #expect(controller.statuses[.claude] == claude)
    #expect(await service.requestedProviders == [.codex, .claude])
  }

  @Test func failedRefreshPreservesLastKnownStatus() async {
    let previous = Self.status(provider: .claude, state: .partialOutage)
    let service = RecordingProviderStatusService(results: [.claude: .failure])
    let controller = ProviderStatusController(
      service: service,
      initialStatuses: [.claude: previous]
    )

    await controller.refresh(.claude, forceRefresh: true)

    #expect(controller.statuses[.claude] == previous)
    #expect(controller.failedProviders == [.claude])
    #expect(!controller.isRefreshing(.claude))
  }

  @Test func newerRefreshWinsForTheSameProvider() async {
    let service = SequencedProviderStatusService()
    let controller = ProviderStatusController(service: service)

    let first = Task { await controller.refresh(.codex) }
    try? await Task.sleep(for: .milliseconds(10))
    await controller.refresh(.codex, forceRefresh: true)
    await first.value

    #expect(controller.statuses[.codex]?.state == .operational)
    #expect(!controller.isRefreshing(.codex))
  }

  @Test func onlyIssueStatesUseTheDashboardBadge() {
    #expect(!ProviderStatusPresentation(state: .unknown).showsIssueBadge)
    #expect(!ProviderStatusPresentation(state: .operational).showsIssueBadge)
    #expect(ProviderStatusPresentation(state: .degradedPerformance).showsIssueBadge)
    #expect(ProviderStatusPresentation(state: .partialOutage).showsIssueBadge)
    #expect(ProviderStatusPresentation(state: .majorOutage).showsIssueBadge)
  }

  private static func status(
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

private enum ProviderStatusControllerTestError: Error {
  case unavailable
}

private enum ProviderStatusControllerStubResult: Sendable {
  case success(ProviderServiceStatus)
  case failure
}

private actor RecordingProviderStatusService: ProviderStatusServing {
  private(set) var requestedProviders: [UsageProvider] = []
  let results: [UsageProvider: ProviderStatusControllerStubResult]

  init(results: [UsageProvider: ProviderStatusControllerStubResult] = [:]) {
    self.results = results
  }

  func status(
    for provider: UsageProvider,
    forceRefresh: Bool
  ) async throws -> ProviderServiceStatus {
    _ = forceRefresh
    requestedProviders.append(provider)
    switch results[provider] {
    case let .success(status): return status
    case .failure, nil: throw ProviderStatusControllerTestError.unavailable
    }
  }
}

private actor SequencedProviderStatusService: ProviderStatusServing {
  private var requestCount = 0

  func status(
    for provider: UsageProvider,
    forceRefresh: Bool
  ) async throws -> ProviderServiceStatus {
    _ = forceRefresh
    requestCount += 1
    let request = requestCount
    try await Task.sleep(for: request == 1 ? .milliseconds(80) : .milliseconds(1))
    return ProviderServiceStatus(
      provider: provider,
      state: request == 1 ? .degradedPerformance : .operational,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(request)),
      statusPageURL: provider.statusPageURL
    )
  }
}
