import Foundation

/// Log-change batching windows. In Low Power Mode the user has asked macOS to
/// trade freshness for battery, so bursts from an active CLI session are
/// coalesced over longer windows and wake the scanner less often.
public enum UsageInsightsBatchTiming {
  public static let lowPowerQuietPeriodMultiplier: UInt64 = 5
  public static let lowPowerMaximumDelayMultiplier: UInt64 = 4

  public static func effective(
    quietPeriod: UInt64,
    maximumDelay: UInt64,
    isLowPowerModeEnabled: Bool
  ) -> (quietPeriod: UInt64, maximumDelay: UInt64) {
    guard isLowPowerModeEnabled else { return (quietPeriod, maximumDelay) }
    let quiet = clampedProduct(quietPeriod, lowPowerQuietPeriodMultiplier)
    let delay = max(quiet, clampedProduct(maximumDelay, lowPowerMaximumDelayMultiplier))
    return (quiet, delay)
  }

  private static func clampedProduct(_ value: UInt64, _ multiplier: UInt64) -> UInt64 {
    let product = value.multipliedReportingOverflow(by: multiplier)
    return product.overflow ? .max : product.partialValue
  }
}
