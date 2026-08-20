import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringSelectionTests {
  @Test func legacyPersistedSelectionMigratesToEveryDiscoveredAccount() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: [MonitoringFixture.work]])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refreshAccountUsage(for: .codex, force: true)

    #expect(fixture.store.monitoredAccounts[.codex] == [
      MonitoringFixture.personal,
      MonitoringFixture.work,
    ])
    #expect(fixture.store.isMonitoring(MonitoringFixture.work))
    #expect(fixture.store.isMonitoring(MonitoringFixture.personal))
    #expect(await fixture.recorder.names == ["Personal", "Work"])
  }

  @Test func legacyEmptySelectionMigratesToEveryDiscoveredAccount() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: []])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refreshAccountUsage(for: .codex, force: true)

    #expect(fixture.store.monitoredAccounts[.codex] == [
      MonitoringFixture.personal,
      MonitoringFixture.work,
    ])
    #expect(try fixture.monitoringStore.load()[.codex] == [
      MonitoringFixture.personal,
      MonitoringFixture.work,
    ])
    #expect(await fixture.recorder.names == ["Personal", "Work"])
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
    #expect(try fixture.monitoringStore.load()[.codex] == [saved, MonitoringFixture.work])
  }

  @Test func linkedLiveValidationPreservesItsSourceAndUsesTheSavedCorrelation() async throws {
    let live = MonitoringFixture.personal
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let lifecycleRecorder = AppCredentialLifecycleEventRecorder()
    let fixture = try MonitoringFixture(
      accounts: [live],
      capturedCopies: [live.id: saved],
      monitored: [.codex: [live]],
      credentialLifecycleLogger: lifecycleRecorder.logger
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refreshAccountUsage(for: .codex, force: true)

    let validations = lifecycleRecorder.events.filter {
      $0.kind == .validationStarted || $0.kind == .validationSucceeded
    }
    #expect(validations.map(\.source) == [.codexFile, .codexFile])
    #expect(validations.allSatisfy { $0.accountID == "opaque:\(saved.id)" })
  }

  @Test func emptyFirstScanPersistsEmptyUntilAnAccountAppears() async throws {
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery())
    let fixture = try MonitoringFixture(
      accounts: [],
      monitored: nil,
      accountDiscovery: discovery
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()
    #expect(try fixture.monitoringStore.load()[.codex] == [])

    discovery.update(StaticAccountDiscovery(accounts: [.codex: [MonitoringFixture.personal]]))
    await fixture.store.reloadAccounts()

    #expect(fixture.store.monitoredAccounts[.codex] == [MonitoringFixture.personal])
    #expect(try fixture.monitoringStore.load()[.codex] == [MonitoringFixture.personal])
  }

  @Test func laterCaptureMigratesPersistedLiveSelectionToManagedIdentity() async throws {
    let live = MonitoringFixture.personal
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let fixture = try MonitoringFixture(
      accounts: [live],
      capturedCopies: [live.id: saved],
      monitored: [.codex: [live]]
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.monitoredAccounts[.codex] == [live])
    #expect(try fixture.monitoringStore.load()[.codex] == [saved])
  }

  @Test func replacedMutableSlotIsAutomaticallyMonitored() async throws {
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

    #expect(fixture.store.monitoredAccounts[.codex] == [replacement])
    #expect(try fixture.monitoringStore.load()[.codex] == [replacement])
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

  @Test func reenablingProviderRestoresEveryMonitoredAccountImmediately() async throws {
    let fixture = try MonitoringFixture(
      selected: [.codex: MonitoringFixture.work],
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]]
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    fixture.store.setProviderEnabled(.codex, enabled: false)
    fixture.store.setProviderEnabled(.codex, enabled: true)
    await fixture.store.selectionRefreshTasks[.codex]?.value

    #expect(await fixture.recorder.names == ["Work", "Personal"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal)?.snapshot != nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func automaticRefreshAttributesAndExcludesTheCredentialReportedByTheProvider() async throws {
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]],
      automaticCredentialScopeID: MonitoringFixture.work.credentialScopeID
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refresh()

    #expect(await fixture.recorder.names == ["Automatic", "Personal"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal)?.snapshot != nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func automaticRotationExcludesItsPreviousCredentialScope() async throws {
    let rotatedScopeID = "\(MonitoringFixture.work.credentialScopeID):rotated"
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.personal, MonitoringFixture.work]],
      automaticCredentialScopeID: rotatedScopeID,
      automaticTransitionSourceScopeIDs: [MonitoringFixture.work.credentialScopeID]
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refresh()

    #expect(await fixture.recorder.names == ["Automatic", "Personal"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func periodicRefreshRediscoveryMonitorsAReplacedCredentialSlot() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:saved")
    )
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement",
      detail: "Default",
      credentialSource: MonitoringFixture.personal.credentialSource,
      credentialIdentity: "replacement"
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.codex: [MonitoringFixture.personal, saved]]
    ))
    let fixture = try MonitoringFixture(
      accounts: [],
      selected: [.codex: saved],
      monitored: [.codex: [MonitoringFixture.personal]],
      accountDiscovery: discovery
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    discovery.update(StaticAccountDiscovery(accounts: [.codex: [replacement, saved]]))

    await fixture.store.refresh()

    #expect(await fixture.recorder.names == ["Saved", "Replacement"])
    #expect(fixture.store.monitoredAccounts[.codex] == [replacement, saved])
    #expect(fixture.store.accountUsage(for: replacement)?.snapshot != nil)
  }

  @Test func accountRefreshRejectsUsageFromAReplacedCredentialScope() async throws {
    let fixture = try MonitoringFixture(
      accounts: [MonitoringFixture.personal],
      monitored: [.codex: [MonitoringFixture.personal]],
      explicitCredentialScopeID: MonitoringFixture.work.credentialScopeID
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    await fixture.store.refreshAccountUsage(for: .codex, force: true)

    #expect(await fixture.recorder.names == ["Personal"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal) == nil)
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
final class MonitoringFixture {
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
    monitored: [UsageProvider: [ProviderAccount]]?,
    rawMonitoringData: Data? = nil,
    accountDiscovery: (any ProviderAccountDiscovering)? = nil,
    automaticCredentialScopeID: String? = nil,
    automaticAccountName: String? = nil,
    explicitCredentialScopeID: String? = nil,
    automaticFailureTransitionTargetScopeID: String? = nil,
    automaticTransitionSourceScopeIDs: Set<String> = [],
    strategyGate: MonitoringUsageGate? = nil,
    credentialLifecycleLogger: CredentialLifecycleLogger = .disabled
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
    if let rawMonitoringData {
      try rawMonitoringData.write(to: monitoringStore.url)
    } else if let monitored {
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
      pipeline: ProviderFetchPipeline { _ in
        [MonitoringUsageStrategy(
          recorder: recorder,
          automaticCredentialScopeID: automaticCredentialScopeID,
          automaticAccountName: automaticAccountName,
          explicitCredentialScopeID: explicitCredentialScopeID,
          automaticFailureTransitionTargetScopeID: automaticFailureTransitionTargetScopeID,
          automaticTransitionSourceScopeIDs: automaticTransitionSourceScopeIDs,
          gate: strategyGate
        )]
      }
    )
    store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: accountDiscovery ?? StaticAccountDiscovery(
        accounts: [.codex: accounts],
        capturedCopies: capturedCopies
      ),
      accountSelectionStore: selectionStore,
      accountMonitoringStore: monitoringStore,
      credentialLifecycleLogger: credentialLifecycleLogger,
      startsAutomatically: false
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
