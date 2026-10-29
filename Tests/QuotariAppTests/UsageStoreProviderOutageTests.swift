import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreProviderOutageTests {
  @Test func anOpenIncidentBadgesTheMenuBarAndIsAnnounced() async {
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      providerStatus: ProviderStatusController(service: IncidentStatusService()),
      startsAutomatically: false
    )
    #expect(!store.hasActiveProviderOutage)

    await store.providerStatus.refresh(.codex)

    #expect(store.hasActiveProviderOutage)
    #expect(store.menuBarAccessibilityLabel.hasSuffix(", service incident"))
  }
}

private struct IncidentStatusService: ProviderStatusServing {
  func status(for provider: UsageProvider, forceRefresh: Bool) async throws -> ProviderServiceStatus {
    ProviderServiceStatus(
      provider: provider,
      state: .partialOutage,
      updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
      statusPageURL: provider.statusPageURL,
      incident: ProviderStatusIncident(
        id: "incident-1", name: "Elevated errors", status: "investigating", impact: "major",
        url: provider.statusPageURL
      )
    )
  }
}
