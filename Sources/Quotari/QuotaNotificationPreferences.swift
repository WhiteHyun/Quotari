import Foundation
import QuotariCore

struct QuotaNotificationPreferences: Codable, Equatable, Sendable {
  var isEnabled: Bool
  var warningThreshold: Int
  var criticalThreshold: Int
  var enabledProviders: Set<UsageProvider>

  init(
    isEnabled: Bool = false,
    warningThreshold: Int = 80,
    criticalThreshold: Int = 95,
    enabledProviders: Set<UsageProvider> = Set(UsageProvider.allCases)
  ) {
    self.isEnabled = isEnabled
    self.warningThreshold = warningThreshold
    self.criticalThreshold = criticalThreshold
    self.enabledProviders = enabledProviders
  }
}
