@testable import Quotari
@testable import QuotariCore
import Testing

struct QuotaBarThresholdsTests {
  @Test func mapsUsedThresholdsOntoRemainingQuotaAxis() throws {
    let thresholds = try #require(QuotaBarThresholds(
      preferences: enabledPreferences(),
      provider: .codex
    ))

    #expect(thresholds.warningRemainingFraction == 0.2)
    #expect(thresholds.criticalRemainingFraction == 0.05)
  }

  @Test func splitsHealthyRemainingQuotaAcrossRiskZones() throws {
    let thresholds = try #require(QuotaBarThresholds(
      preferences: enabledPreferences(),
      provider: .codex
    ))
    let segments = thresholds.segments(forRemainingPercent: 69)

    #expect(abs(segments.criticalFraction - 0.05) < 0.0001)
    #expect(abs(segments.warningFraction - 0.15) < 0.0001)
    #expect(abs(segments.providerFraction - 0.49) < 0.0001)
  }

  @Test func truncatesRiskZonesAtCurrentRemainingQuota() throws {
    let thresholds = try #require(QuotaBarThresholds(
      preferences: enabledPreferences(),
      provider: .codex
    ))

    let warning = thresholds.segments(forRemainingPercent: 12)
    #expect(abs(warning.criticalFraction - 0.05) < 0.0001)
    #expect(abs(warning.warningFraction - 0.07) < 0.0001)
    #expect(warning.providerFraction == 0)

    let critical = thresholds.segments(forRemainingPercent: 3)
    #expect(abs(critical.criticalFraction - 0.03) < 0.0001)
    #expect(critical.warningFraction == 0)
    #expect(critical.providerFraction == 0)
  }

  @Test func hidesRiskZonesWhenNotificationsAreDisabled() {
    let preferences = QuotaNotificationPreferences(
      isEnabled: false,
      warningThreshold: 80,
      criticalThreshold: 95
    )

    #expect(QuotaBarThresholds(preferences: preferences, provider: .codex) == nil)
  }

  @Test func hidesRiskZonesForDisabledProvider() {
    let preferences = QuotaNotificationPreferences(
      isEnabled: true,
      warningThreshold: 80,
      criticalThreshold: 95,
      enabledProviders: [.claude]
    )

    #expect(QuotaBarThresholds(preferences: preferences, provider: .codex) == nil)
  }

  private func enabledPreferences() -> QuotaNotificationPreferences {
    QuotaNotificationPreferences(
      isEnabled: true,
      warningThreshold: 80,
      criticalThreshold: 95
    )
  }
}
