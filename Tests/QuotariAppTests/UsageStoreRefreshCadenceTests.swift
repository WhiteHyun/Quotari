import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreRefreshCadenceTests {
  @Test func adaptiveRefreshFollowsCLIActivityAndPersistsTheMode() throws {
    let defaults = try #require(UserDefaults(suiteName: "refresh-cadence-\(UUID().uuidString)"))
    let store = UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      defaults: defaults,
      startsAutomatically: false
    )
    store.refreshInterval = 300
    store.cliActivityProbe = { _ in true }

    #expect(store.refreshMode == .adaptive)
    #expect(store.nextRefreshInterval(quotaMoved: false) == 150)

    store.cliActivityProbe = { _ in false }
    #expect(store.nextRefreshInterval(quotaMoved: false) == 600)
    #expect(store.nextRefreshInterval(quotaMoved: true) == 150)

    store.refreshMode = .fixed
    #expect(store.nextRefreshInterval(quotaMoved: true) == 300)
    #expect(UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      defaults: defaults,
      startsAutomatically: false
    ).refreshMode == .fixed)
  }

  @Test func aRateLimitBacksOffOnlyTheNextCycle() {
    let store = UsageStore.isolatedForTesting(providers: ProviderFixtures.descriptors, startsAutomatically: false)
    store.refreshInterval = 60
    store.cliActivityProbe = { _ in true }

    store.noteFetchFailure(ProviderHTTPError.rateLimited(retryAfter: nil))

    #expect(store.nextRefreshInterval(quotaMoved: false) == 240)
    #expect(store.nextRefreshInterval(quotaMoved: false) == 60)
  }
}
