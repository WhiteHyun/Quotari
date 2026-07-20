import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreRefreshIntervalTests {
  @Test func persistsIntervalChangeAndRestoresItOnNextLaunch() throws {
    let suiteName = "quotari-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = makeStore(defaults: defaults)
    store.refreshInterval = 300

    #expect(defaults.double(forKey: UsageStore.refreshIntervalDefaultsKey) == 300)
    #expect(makeStore(defaults: defaults).refreshInterval == 300)
  }

  @Test func fallsBackToDefaultIntervalWhenNothingIsSaved() throws {
    let suiteName = "quotari-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(makeStore(defaults: defaults).refreshInterval == 60)
  }

  @Test(arguments: [
    (saved: 5.0, restored: 60.0),
    (saved: 7200.0, restored: 1800.0),
    (saved: -30.0, restored: 60.0),
  ])
  func clampsOutOfRangeSavedIntervals(saved: Double, restored: Double) throws {
    let suiteName = "quotari-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(saved, forKey: UsageStore.refreshIntervalDefaultsKey)

    #expect(makeStore(defaults: defaults).refreshInterval == restored)
  }

  @Test func restoringSavedIntervalDoesNotStartTheTimer() throws {
    let suiteName = "quotari-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(300.0, forKey: UsageStore.refreshIntervalDefaultsKey)

    let store = makeStore(defaults: defaults)

    #expect(store.refreshInterval == 300)
    #expect(store.timerTask == nil)
  }

  private func makeStore(defaults: UserDefaults) -> UsageStore {
    let selectionURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-refresh-interval-\(UUID().uuidString).json")
    return UsageStore.isolatedForTesting(
      providers: ProviderFixtures.descriptors,
      accountSelectionStore: ProviderAccountSelectionStore(url: selectionURL),
      defaults: defaults,
      startsAutomatically: false
    )
  }
}
