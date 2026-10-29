import Foundation
import QuotariCore

struct QuotaNotificationPreferences: Codable, Equatable, Sendable {
  var isEnabled: Bool
  var warningThreshold: Int
  var criticalThreshold: Int
  var enabledProviders: Set<UsageProvider>
  var remindsBeforeResetCreditsExpire: Bool
  var alertsOnProviderOutages: Bool
  /// Off by default: suggest a monitored saved account when the active one
  /// reaches the critical threshold.
  var suggestsAccountSwitch: Bool

  init(
    isEnabled: Bool = false,
    warningThreshold: Int = 80,
    criticalThreshold: Int = 95,
    enabledProviders: Set<UsageProvider> = Set(UsageProvider.allCases),
    remindsBeforeResetCreditsExpire: Bool = true,
    alertsOnProviderOutages: Bool = false,
    suggestsAccountSwitch: Bool = false
  ) {
    self.isEnabled = isEnabled
    self.warningThreshold = warningThreshold
    self.criticalThreshold = criticalThreshold
    self.enabledProviders = enabledProviders
    self.remindsBeforeResetCreditsExpire = remindsBeforeResetCreditsExpire
    self.alertsOnProviderOutages = alertsOnProviderOutages
    self.suggestsAccountSwitch = suggestsAccountSwitch
  }

  /// Fields added after release decode with their defaults, so preferences saved
  /// by an older version keep loading instead of resetting to defaults.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    warningThreshold = try container.decode(Int.self, forKey: .warningThreshold)
    criticalThreshold = try container.decode(Int.self, forKey: .criticalThreshold)
    enabledProviders = try container.decode(Set<UsageProvider>.self, forKey: .enabledProviders)
    remindsBeforeResetCreditsExpire = try container.decodeIfPresent(
      Bool.self,
      forKey: .remindsBeforeResetCreditsExpire
    ) ?? true
    alertsOnProviderOutages = try container.decodeIfPresent(
      Bool.self,
      forKey: .alertsOnProviderOutages
    ) ?? false
    suggestsAccountSwitch = try container.decodeIfPresent(Bool.self, forKey: .suggestsAccountSwitch) ?? false
  }
}
