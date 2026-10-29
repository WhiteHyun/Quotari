import Foundation
@testable import Quotari
import Testing

struct RefreshCadenceTests {
  @Test func fixedModeAlwaysUsesTheChosenInterval() {
    #expect(RefreshCadence.interval(base: 300, mode: .fixed, isActive: true, wasRateLimited: false) == 300)
    #expect(RefreshCadence.interval(base: 300, mode: .fixed, isActive: false, wasRateLimited: true) == 300)
  }

  @Test func activeWorkRefreshesTwiceAsOftenButNeverBelowAMinute() {
    #expect(RefreshCadence.interval(base: 300, mode: .adaptive, isActive: true, wasRateLimited: false) == 150)
    #expect(RefreshCadence.interval(base: 60, mode: .adaptive, isActive: true, wasRateLimited: false) == 60)
  }

  @Test func idleTimeRefreshesHalfAsOftenWithinHalfAnHour() {
    #expect(RefreshCadence.interval(base: 300, mode: .adaptive, isActive: false, wasRateLimited: false) == 600)
    #expect(RefreshCadence.interval(base: 1200, mode: .adaptive, isActive: false, wasRateLimited: false) == 1800)
    // Idle never refreshes more often than the chosen interval.
    #expect(RefreshCadence.interval(base: 1800, mode: .adaptive, isActive: false, wasRateLimited: false) == 1800)
  }

  @Test func aRateLimitBacksOffEvenWhileActive() {
    #expect(RefreshCadence.interval(base: 60, mode: .adaptive, isActive: true, wasRateLimited: true) == 240)
    #expect(RefreshCadence.interval(base: 1800, mode: .adaptive, isActive: false, wasRateLimited: true) == 3600)
  }
}
