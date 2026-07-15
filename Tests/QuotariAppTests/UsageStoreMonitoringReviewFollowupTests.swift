import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringReviewFollowupTests {
  @Test func stoppingOneLiveAliasStopsEveryAliasOfTheManagedAccount() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Shared",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:shared")
    )
    let fixture = try MonitoringFixture(
      capturedCopies: [
        MonitoringFixture.personal.id: saved,
        MonitoringFixture.work.id: saved,
      ],
      monitored: nil
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    #expect(fixture.store.monitoredAccounts[.codex] == [
      MonitoringFixture.personal,
      MonitoringFixture.work,
    ])

    fixture.store.setMonitoring(false, for: MonitoringFixture.personal)

    #expect(fixture.store.monitoredAccounts[.codex] == [])
    #expect(try fixture.monitoringStore.load()[.codex] == [])
  }

  @Test func unavailableSelectionPlaceholderDoesNotConfigureFirstScanMonitoring() async throws {
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery())
    let fixture = try MonitoringFixture(
      accounts: [],
      selected: [.codex: MonitoringFixture.personal],
      monitored: nil,
      accountDiscovery: discovery
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.accounts[.codex] == [MonitoringFixture.personal])
    #expect(fixture.store.monitoredAccounts[.codex] == [])
    #expect(try fixture.monitoringStore.load()[.codex] == nil)

    discovery.update(StaticAccountDiscovery(accounts: [.codex: [MonitoringFixture.work]]))
    await fixture.store.reloadAccounts()

    #expect(fixture.store.monitoredAccounts[.codex] == [MonitoringFixture.work])
    #expect(try fixture.monitoringStore.load()[.codex] == [MonitoringFixture.work])
  }

  @Test func failedAutomaticRotationStillExcludesItsProvenSourceScope() async throws {
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]],
      automaticFailureTransitionTargetScopeID: "codex:rotated",
      automaticTransitionSourceScopeIDs: [MonitoringFixture.personal.credentialScopeID]
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refresh()

    #expect(await fixture.recorder.names == ["Automatic", "Work"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal) == nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func mismatchedSelectedFetchDoesNotSuppressOrCorruptTheReportedAccount() async throws {
    let fixture = try MonitoringFixture(
      selected: [.codex: MonitoringFixture.personal],
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]],
      explicitCredentialScopeID: MonitoringFixture.work.credentialScopeID
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refresh()

    let names = await fixture.recorder.names
    #expect(names.first == "Personal")
    #expect(names.count == 3)
    #expect(Set(names.dropFirst()) == ["Personal", "Work"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal) == nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func implicitFetchMirrorsTheActiveCLIRowInsteadOfDiscoveryOrder() async throws {
    let personalSaved = ProviderAccount(
      provider: .codex,
      displayName: "Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let workSaved = ProviderAccount(
      provider: .codex,
      displayName: "Work",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:work")
    )
    let discovery = ActiveAccountDiscovery(
      accounts: [MonitoringFixture.personal, MonitoringFixture.work],
      activeAccount: MonitoringFixture.work,
      capturedCopies: [
        MonitoringFixture.personal.id: personalSaved,
        MonitoringFixture.work.id: workSaved,
      ]
    )
    let fixture = try MonitoringFixture(
      accounts: [],
      monitored: [.codex: []],
      accountDiscovery: discovery
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    #expect(fixture.store.capturedRegistryIDForFetch(
      provider: .codex,
      selectedAccount: nil
    ) == "codex:work")
  }
}

private struct ActiveAccountDiscovery: ProviderAccountDiscovering {
  var accounts: [ProviderAccount]
  var activeAccount: ProviderAccount
  var capturedCopies: [String: ProviderAccount]

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    provider == .codex ? accounts : []
  }

  func activeCLIAccount(
    for provider: UsageProvider,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    provider == .codex ? activeAccount : nil
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    capturedCopies
  }
}
