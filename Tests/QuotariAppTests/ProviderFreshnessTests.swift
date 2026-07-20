import Foundation
@testable import Quotari
import Testing

struct ProviderFreshnessTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func formatsElapsedTimeCompactly() {
    #expect(freshness(secondsAgo: 30).updatedText == "Updated just now")
    #expect(freshness(secondsAgo: 60).updatedText == "Updated 1m ago")
    #expect(freshness(secondsAgo: 3599).updatedText == "Updated 59m ago")
    #expect(freshness(secondsAgo: 3600).updatedText == "Updated 1h ago")
    #expect(freshness(secondsAgo: 86400).updatedText == "Updated 1d ago")
  }

  @Test func treatsFutureDatesAsJustUpdated() {
    #expect(freshness(secondsAgo: -60).updatedText == "Updated just now")
  }

  @Test func becomesStaleAfterTwoRefreshIntervals() {
    #expect(!freshness(secondsAgo: 599, refreshInterval: 300).isStale)
    #expect(!freshness(secondsAgo: 600, refreshInterval: 300).isStale)
    #expect(freshness(secondsAgo: 601, refreshInterval: 300).isStale)
  }

  @Test func exposesStalenessWithoutRelyingOnColor() {
    #expect(
      freshness(secondsAgo: 601, refreshInterval: 300)
        .accessibilityText(sourceLabel: "Live API") == "Live API, Stale, updated 10m ago"
    )
  }

  private func freshness(
    secondsAgo: TimeInterval,
    refreshInterval: TimeInterval = 300
  ) -> ProviderFreshness {
    ProviderFreshness(
      updatedAt: now.addingTimeInterval(-secondsAgo),
      now: now,
      refreshInterval: refreshInterval
    )
  }
}
