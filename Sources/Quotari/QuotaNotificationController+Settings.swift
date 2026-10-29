import Foundation
import QuotariCore

/// Settable surfaces for SwiftUI bindings in Settings.
extension QuotaNotificationController {
  var authorizationMessage: String? {
    authorizationStatus == .denied
      ? L10n.string("Allow notifications for Quotari in System Settings to enable quota alerts.")
      : nil
  }

  var notificationsEnabled: Bool {
    get { preferences.isEnabled }
    set {
      guard newValue != preferences.isEnabled else { return }
      Task { @MainActor [weak self] in
        await self?.setNotificationsEnabled(newValue)
      }
    }
  }

  var warningThreshold: Int {
    get { preferences.warningThreshold }
    set {
      _ = updateThresholds(
        warning: newValue,
        critical: preferences.criticalThreshold
      )
    }
  }

  var criticalThreshold: Int {
    get { preferences.criticalThreshold }
    set {
      _ = updateThresholds(
        warning: preferences.warningThreshold,
        critical: newValue
      )
    }
  }

  subscript(providerEnabled provider: UsageProvider) -> Bool {
    get { preferences.enabledProviders.contains(provider) }
    set { setProvider(provider, enabled: newValue) }
  }

  var remindsBeforeResetCreditsExpire: Bool {
    get { preferences.remindsBeforeResetCreditsExpire }
    set { setResetCreditRemindersEnabled(newValue) }
  }
}
