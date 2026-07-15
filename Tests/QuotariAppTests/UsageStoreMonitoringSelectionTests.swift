import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringSelectionTests {
  @Test func persistedSelectionFetchesOnlyMonitoredAccounts() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: [MonitoringFixture.work]])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refreshAccountUsage(for: .codex, force: true)

    #expect(fixture.store.monitoredAccounts[.codex] == [MonitoringFixture.work])
    #expect(fixture.store.isMonitoring(MonitoringFixture.work))
    #expect(!fixture.store.isMonitoring(MonitoringFixture.personal))
    #expect(await fixture.recorder.names == ["Work"])
  }

  @Test func explicitEmptySelectionSurvivesReloadAndSkipsAccountRefresh() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: []])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refreshAccountUsage(for: .codex, force: true)

    #expect(fixture.store.monitoredAccounts[.codex] == [])
    #expect(fixture.monitoringStore.load()[.codex] == [])
    #expect(await fixture.recorder.names.isEmpty)
  }

  @Test func firstScanMonitorsEveryAccountAndPersistsManagedIdentity() async throws {
    let live = MonitoringFixture.personal
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal"),
      credentialIdentity: "personal"
    )
    let fixture = try MonitoringFixture(
      accounts: [live, MonitoringFixture.work],
      capturedCopies: [live.id: saved],
      monitored: nil
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.monitoredAccounts[.codex] == [live, MonitoringFixture.work])
    #expect(fixture.monitoringStore.load()[.codex] == [saved, MonitoringFixture.work])
  }

  @Test func replacedMutableSlotDoesNotInheritMonitoringSelection() async throws {
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement",
      detail: "Default",
      credentialSource: MonitoringFixture.personal.credentialSource,
      credentialIdentity: "replacement"
    )
    let fixture = try MonitoringFixture(
      accounts: [replacement],
      monitored: [.codex: [MonitoringFixture.personal]]
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.monitoredAccounts[.codex] == [])
    #expect(fixture.monitoringStore.load()[.codex] == [MonitoringFixture.personal])
  }

  @Test func periodicRefreshFetchesDashboardAndOtherMonitoredAccountsOnceEach() async throws {
    let fixture = try MonitoringFixture(
      selected: [.codex: MonitoringFixture.work],
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]]
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refresh()

    #expect(await fixture.recorder.names == ["Work", "Personal"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal)?.snapshot != nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func dashboardSelectionDoesNotChangeTheCLIActiveAccount() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:saved")
    )
    let fixture = try MonitoringFixture(
      accounts: [MonitoringFixture.personal, saved],
      selected: [.codex: saved],
      monitored: [.codex: [saved]]
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.selectedAccounts[.codex] == saved)
    #expect(fixture.store.activeCLIAccount(for: .codex) == MonitoringFixture.personal)
  }
}

@MainActor
private final class MonitoringFixture {
  static let personal = ProviderAccount(
    provider: .codex,
    displayName: "Personal",
    detail: "Default",
    credentialSource: .codexAuthFile(path: "/tmp/personal/auth.json"),
    credentialIdentity: "personal"
  )
  static let work = ProviderAccount(
    provider: .codex,
    displayName: "Work",
    detail: "CODEX_HOME",
    credentialSource: .codexAuthFile(path: "/tmp/work/auth.json"),
    credentialIdentity: "work"
  )

  let directory: URL
  let monitoringStore: ProviderAccountMonitoringStore
  let recorder = MonitoringUsageRecorder()
  let store: UsageStore

  init(
    accounts: [ProviderAccount] = [personal, work],
    capturedCopies: [String: ProviderAccount] = [:],
    selected: [UsageProvider: ProviderAccount] = [:],
    monitored: [UsageProvider: [ProviderAccount]]?
  ) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-monitoring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.appendingPathComponent("ProviderAccounts.json")
    )
    try selectionStore.save(selected)
    monitoringStore = ProviderAccountMonitoringStore(
      url: directory.appendingPathComponent("MonitoredProviderAccounts.json")
    )
    if let monitored {
      try monitoringStore.save(monitored)
    }
    let recorder = recorder
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [MonitoringUsageStrategy(recorder: recorder)] }
    )
    store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: accounts],
        capturedCopies: capturedCopies
      ),
      accountSelectionStore: selectionStore,
      accountMonitoringStore: monitoringStore,
      startsAutomatically: false
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private actor MonitoringUsageRecorder {
  private(set) var names: [String] = []

  func record(_ account: ProviderAccount?) {
    names.append(account?.displayName ?? "Automatic")
  }
}

private struct MonitoringUsageStrategy: ProviderFetchStrategy {
  let recorder: MonitoringUsageRecorder
  let id = "monitoring-usage"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    await recorder.record(context.account)
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        primary: RateWindow(kind: .session, usedPercent: 25),
        secondary: nil,
        updatedAt: context.now
      ),
      sourceLabel: "Test"
    )
  }
}
