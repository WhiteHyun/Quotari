import Foundation
@testable import Quotari
@testable import QuotariCore

/// Status checks in tests never reach a real status page.
struct OfflineProviderStatusService: ProviderStatusServing {
  func status(for provider: UsageProvider, forceRefresh: Bool) async throws -> ProviderServiceStatus {
    throw URLError(.notConnectedToInternet)
  }
}

@MainActor
final class UnavailableQuotaNotificationCenter: QuotaNotificationCenterTransport {
  func authorizationStatus() async -> QuotaNotificationAuthorizationStatus {
    .denied
  }

  func requestAuthorization() async throws -> Bool {
    false
  }

  func pendingScheduledRequestIdentifiers() async -> Set<String> {
    []
  }

  func add(_ request: QuotaNotificationRequest) async throws {}

  func addResetCreditReminder(_ reminder: ResetCreditReminder) async throws {}

  func addProviderStatusAlert(_ alert: ProviderStatusAlert) async throws {}

  func removePendingRequests(withIdentifiers identifiers: [String]) {}

  func removeRequests(withIdentifiers identifiers: [String]) {}

  func configureForegroundPresentation() {}
}
