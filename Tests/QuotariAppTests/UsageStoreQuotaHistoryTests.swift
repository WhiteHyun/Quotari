import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreQuotaHistoryTests {
  @Test func aSuccessfulRefreshRecordsEachWindowReading() async throws {
    let store = UsageStore.isolatedForTesting(providers: ProviderFixtures.descriptors, startsAutomatically: false)

    await store.refresh()

    let snapshot = try #require(store.snapshots[.codex])
    let session = try #require(snapshot.primary)
    #expect(store.quotaHistoryReadings(for: .codex, window: session).map(\.usedPercent) == [session.usedPercent])
  }

  @Test func weekdayPaceFollowsThePreference() {
    let store = UsageStore.isolatedForTesting(providers: ProviderFixtures.descriptors, startsAutomatically: false)
    #expect(!store.paceCountsWeekdaysOnly)

    store.paceCountsWeekdaysOnly = true

    #expect(store.paceCountsWeekdaysOnly)
  }
}
