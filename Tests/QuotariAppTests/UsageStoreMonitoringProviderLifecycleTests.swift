@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MonitoringProviderLifecycleTests {
  @Test func reenablingProviderRediscoversBeforeRestoringMonitoredUsage() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement",
      detail: "Default",
      credentialSource: MonitoringFixture.personal.credentialSource,
      credentialIdentity: "replacement"
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.codex: [MonitoringFixture.personal]],
      capturedCopies: [MonitoringFixture.personal.id: saved]
    ))
    let fixture = try MonitoringFixture(
      monitored: [.codex: [saved]],
      accountDiscovery: discovery,
      automaticCredentialScopeID: replacement.credentialScopeID,
      automaticAccountName: replacement.displayName
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    #expect(fixture.store.monitoredAccounts[.codex] == [MonitoringFixture.personal])

    fixture.store.setProviderEnabled(.codex, enabled: false)
    discovery.update(StaticAccountDiscovery(accounts: [.codex: [replacement, saved]]))
    fixture.store.setProviderEnabled(.codex, enabled: true)
    await fixture.store.selectionRefreshTasks[.codex]?.value

    #expect(fixture.store.monitoredAccounts[.codex] == [saved])
    #expect(await fixture.recorder.names == ["Automatic", "Saved Personal"])
    #expect(fixture.store.accountUsage(for: saved)?.snapshot != nil)
  }
}
