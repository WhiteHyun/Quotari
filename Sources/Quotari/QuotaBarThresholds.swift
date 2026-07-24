import QuotariCore

struct QuotaBarSegments: Equatable {
  let criticalFraction: Double
  let warningFraction: Double
  let providerFraction: Double
}

struct QuotaBarThresholds: Equatable {
  let warningUsedPercent: Int
  let criticalUsedPercent: Int

  init?(
    preferences: QuotaNotificationPreferences,
    provider: UsageProvider
  ) {
    guard preferences.isEnabled,
          preferences.enabledProviders.contains(provider)
    else { return nil }

    warningUsedPercent = preferences.warningThreshold
    criticalUsedPercent = preferences.criticalThreshold
  }

  var warningRemainingFraction: Double {
    remainingFraction(forUsedThreshold: warningUsedPercent)
  }

  var criticalRemainingFraction: Double {
    remainingFraction(forUsedThreshold: criticalUsedPercent)
  }

  func segments(forRemainingPercent remainingPercent: Double) -> QuotaBarSegments {
    let remainingFraction = min(1, max(0, remainingPercent / 100))
    let criticalEnd = min(remainingFraction, criticalRemainingFraction)
    let warningEnd = min(remainingFraction, warningRemainingFraction)

    return QuotaBarSegments(
      criticalFraction: criticalEnd,
      warningFraction: max(0, warningEnd - criticalEnd),
      providerFraction: max(0, remainingFraction - warningEnd)
    )
  }

  private func remainingFraction(forUsedThreshold threshold: Int) -> Double {
    min(1, max(0, Double(100 - threshold) / 100))
  }
}
