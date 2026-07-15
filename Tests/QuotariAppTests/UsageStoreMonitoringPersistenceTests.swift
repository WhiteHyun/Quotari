import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringPersistenceTests {
  @Test func malformedSelectionFailsClosedWithoutOverwritingTheFile() async throws {
    let malformed = Data("not-json".utf8)
    let fixture = try MonitoringFixture(
      monitored: nil,
      rawMonitoringData: malformed
    )
    defer { fixture.remove() }

    await fixture.store.reloadAccounts()

    #expect(fixture.store.monitoredAccounts[.codex] == [])
    #expect(try Data(contentsOf: fixture.monitoringStore.url) == malformed)
  }

  @Test func explicitMonitoringChangeRepairsMalformedConfiguration() async throws {
    let fixture = try MonitoringFixture(
      monitored: nil,
      rawMonitoringData: Data("not-json".utf8)
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    fixture.store.setMonitoring(true, for: MonitoringFixture.personal)

    #expect(fixture.store.isMonitoringConfigurationLoaded)
    #expect(try fixture.monitoringStore.load()[.codex] == [MonitoringFixture.personal])
  }

  @Test func explicitMonitoringChangeRetriesAfterWriteFailure() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: [MonitoringFixture.personal]])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    try FileManager.default.removeItem(at: fixture.monitoringStore.url)
    try FileManager.default.createDirectory(
      at: fixture.monitoringStore.url,
      withIntermediateDirectories: true
    )

    fixture.store.setMonitoring(false, for: MonitoringFixture.personal)
    #expect(!fixture.store.isMonitoringConfigurationLoaded)
    try FileManager.default.removeItem(at: fixture.monitoringStore.url)
    fixture.store.setMonitoring(true, for: MonitoringFixture.personal)

    #expect(fixture.store.isMonitoringConfigurationLoaded)
    #expect(try fixture.monitoringStore.load()[.codex] == [MonitoringFixture.personal])
  }

  @Test func unchangedReloadDoesNotRewriteMonitoringConfiguration() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: [MonitoringFixture.personal]])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    let sentinel = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: sentinel],
      ofItemAtPath: fixture.monitoringStore.url.path
    )

    await fixture.store.reloadAccounts()

    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.monitoringStore.url.path)
    #expect(attributes[.modificationDate] as? Date == sentinel)
  }
}
