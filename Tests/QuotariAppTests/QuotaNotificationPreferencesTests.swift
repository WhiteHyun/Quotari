import Foundation
@testable import Quotari
import QuotariCore
import Testing

struct QuotaNotificationPreferencesTests {
  @Test func preferencesSavedBeforeResetCreditRemindersStillLoad() throws {
    let legacy = Data("""
    { "isEnabled": true, "warningThreshold": 70, "criticalThreshold": 90, "enabledProviders": ["codex"] }
    """.utf8)

    let preferences = try JSONDecoder().decode(QuotaNotificationPreferences.self, from: legacy)

    #expect(preferences == QuotaNotificationPreferences(
      isEnabled: true,
      warningThreshold: 70,
      criticalThreshold: 90,
      enabledProviders: [.codex],
      remindsBeforeResetCreditsExpire: true
    ))
  }
}
