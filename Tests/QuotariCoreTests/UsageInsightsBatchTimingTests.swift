import Foundation
@testable import QuotariCore
import Testing

struct UsageInsightsBatchTimingTests {
  private static let second: UInt64 = 1_000_000_000

  @Test func normalPowerKeepsTheConfiguredWindows() {
    let timing = UsageInsightsBatchTiming.effective(
      quietPeriod: 2 * Self.second,
      maximumDelay: 30 * Self.second,
      isLowPowerModeEnabled: false
    )

    #expect(timing.quietPeriod == 2 * Self.second)
    #expect(timing.maximumDelay == 30 * Self.second)
  }

  @Test func lowPowerModeWidensBothWindows() {
    let timing = UsageInsightsBatchTiming.effective(
      quietPeriod: 2 * Self.second,
      maximumDelay: 30 * Self.second,
      isLowPowerModeEnabled: true
    )

    #expect(timing.quietPeriod == 10 * Self.second)
    #expect(timing.maximumDelay == 120 * Self.second)
  }

  @Test func widenedMaximumDelayNeverFallsBelowTheQuietPeriod() {
    let timing = UsageInsightsBatchTiming.effective(
      quietPeriod: 10 * Self.second,
      maximumDelay: 10 * Self.second,
      isLowPowerModeEnabled: true
    )

    #expect(timing.maximumDelay >= timing.quietPeriod)
  }

  @Test func overflowClampsToTheMaximum() {
    let timing = UsageInsightsBatchTiming.effective(
      quietPeriod: .max / 2,
      maximumDelay: .max / 2,
      isLowPowerModeEnabled: true
    )

    #expect(timing.quietPeriod == .max)
    #expect(timing.maximumDelay == .max)
  }
}
