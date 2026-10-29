import Foundation
@testable import Quotari
@testable import QuotariCore
import QuotariSharedSnapshot
import Testing

@MainActor
struct UsageStoreSharedSnapshotTests {
  @Test func aRefreshSharesEachProvidersWindowsWithoutTheAccount() async throws {
    let store = UsageStore.isolatedForTesting(providers: ProviderFixtures.descriptors, startsAutomatically: false)

    await store.refresh()

    let file = store.sharedUsageSnapshotPublisher.file
    guard case let .snapshot(shared) = file.read() else {
      Issue.record("No snapshot was written")
      return
    }
    let codex = try #require(store.snapshots[.codex])
    let sharedCodex = try #require(shared.providers.first { $0.id == "codex" })
    #expect(Set(shared.providers.map(\.id)) == ["claude", "codex"])
    // ISO 8601 in the file keeps whole seconds.
    #expect(abs(sharedCodex.updatedAt.timeIntervalSince(codex.updatedAt)) < 1)
    #expect(sharedCodex.windows.first?.kind == "session")
    #expect(sharedCodex.windows.first?.usedPercent == codex.primary?.usedPercent)
    let raw = try String(contentsOf: file.url, encoding: .utf8)
    for account in store.snapshots.values.compactMap(\.account) {
      #expect(!raw.contains(account))
    }
  }

  @Test func disablingAProviderRemovesItFromTheSnapshot() async {
    let store = UsageStore.isolatedForTesting(providers: ProviderFixtures.descriptors, startsAutomatically: false)
    await store.refresh()

    store.setProviderEnabled(.claude, enabled: false)

    guard case let .snapshot(shared) = store.sharedUsageSnapshotPublisher.file.read() else {
      Issue.record("No snapshot was written")
      return
    }
    #expect(shared.providers.map(\.id) == ["codex"])
  }
}
