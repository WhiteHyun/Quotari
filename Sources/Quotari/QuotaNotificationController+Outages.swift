import Foundation
import QuotariCore

/// A provider status change delivered as an immediate notification.
struct ProviderStatusAlert: Equatable, Sendable {
  var requestID: String
  var event: ProviderOutageEvent

  var provider: UsageProvider {
    switch event {
    case let .started(provider, _), let .resolved(provider, _):
      provider
    }
  }
}

extension QuotaNotificationController {
  /// Delivers an outage start or resolution when the user opted in to outage
  /// alerts for that provider.
  func deliverOutageAlert(_ event: ProviderOutageEvent) async {
    let alert = ProviderStatusAlert(requestID: "quotari.status.\(UUID().uuidString)", event: event)
    guard preferences.isEnabled,
          preferences.alertsOnProviderOutages,
          preferences.enabledProviders.contains(alert.provider)
    else { return }
    do {
      try await center.addProviderStatusAlert(alert)
    } catch {
      lastError = error.localizedDescription
    }
  }
}
