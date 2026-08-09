import CustomDump
import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

/// PS-209: multiple saved registry rows for the same verified Claude profile
/// used to block automatic management forever. Rows whose refresh token the
/// OAuth endpoint definitively rejected are now removed so the live login can
/// converge on one canonical saved row; anything less than that proof keeps
/// the fail-closed behavior.
@MainActor
struct AutomaticCaptureDuplicateHealTests {
  @Test func fullReloadRefreshesCanonicalThenMigratesReferencesAndDeletesRedundantRow() async throws {
    let fixture = try makeDuplicateHealReloadFixture(canonicalAlreadyLive: false)

    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.account(id: fixture.canonicalID))
    expectNoDifference(fixture.registry.load().map(\.id), [fixture.canonicalID])
    #expect(try ClaudeCredentialsStore.parse(saved.payload).accessToken == "live-access")
    #expect(saved.claudeAccountIdentity?.isStrong == true)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == .claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    ))
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.credentialSource == .quotariRegistry(
      id: fixture.canonicalID
    ))
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(
      id: fixture.canonicalID
    ))
    try expectNoDifference(
      fixture.monitoringStore.load()[.claude]?.map(\.credentialSource),
      [.quotariRegistry(id: fixture.canonicalID)]
    )
    #expect(fixture.store.accounts[.claude]?.contains(where: { $0.id == fixture.redundantProviderID }) == false)

    await fixture.store.reloadAccounts()
    expectNoDifference(fixture.registry.load().map(\.id), [fixture.canonicalID])
  }

  @Test func candidateEmptyReloadStillConsolidatesDeadDuplicate() async throws {
    let fixture = try makeDuplicateHealReloadFixture(canonicalAlreadyLive: true)

    await fixture.store.reloadAccounts()

    expectNoDifference(fixture.registry.load().map(\.id), [fixture.canonicalID])
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(
      id: fixture.canonicalID
    ))
    try expectNoDifference(
      fixture.monitoringStore.load()[.claude]?.map(\.credentialSource),
      [.quotariRegistry(id: fixture.canonicalID)]
    )
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.credentialSource == .quotariRegistry(
      id: fixture.canonicalID
    ))
  }

  @Test func selectionWriteFailureKeepsRedundantRowAcrossRetriesThenConverges() async throws {
    let fixture = try makeDuplicateHealReloadFixture(canonicalAlreadyLive: false)
    try blockDuplicateHealPersistenceWrites(at: fixture.selectionStore.url)

    await fixture.store.reloadAccounts()
    expectDuplicateRows(fixture)
    await fixture.store.reloadAccounts()
    expectDuplicateRows(fixture)

    try restoreDuplicateHealPersistenceWrites(at: fixture.selectionStore.url)
    await fixture.store.reloadAccounts()

    expectNoDifference(fixture.registry.load().map(\.id), [fixture.canonicalID])
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(
      id: fixture.canonicalID
    ))
  }

  @Test func monitoringWriteFailureKeepsRedundantRowAcrossRetriesThenConverges() async throws {
    let fixture = try makeDuplicateHealReloadFixture(canonicalAlreadyLive: false)
    try blockDuplicateHealPersistenceWrites(at: fixture.monitoringStore.url)

    await fixture.store.reloadAccounts()
    expectDuplicateRows(fixture)
    await fixture.store.reloadAccounts()
    expectDuplicateRows(fixture)
    #expect(!fixture.store.isMonitoringConfigurationLoaded)

    try restoreDuplicateHealPersistenceWrites(at: fixture.monitoringStore.url)
    // The first healthy reload durably recovers the monitoring map. Cleanup is
    // allowed only on the following scan, once that readable state is known.
    await fixture.store.reloadAccounts()
    expectDuplicateRows(fixture)
    #expect(fixture.store.isMonitoringConfigurationLoaded)
    await fixture.store.reloadAccounts()

    expectNoDifference(fixture.registry.load().map(\.id), [fixture.canonicalID])
    try expectNoDifference(
      fixture.monitoringStore.load()[.claude]?.map(\.credentialSource),
      [.quotariRegistry(id: fixture.canonicalID)]
    )
  }

  @Test func persistedStrongIdentityHealsDuplicatesWithoutProfileCache() async throws {
    let fixture = try makeDuplicateHealReloadFixture(
      canonicalAlreadyLive: false,
      usesPersistedIdentityWithoutProfileCache: true
    )

    await fixture.store.reloadAccounts()

    expectNoDifference(fixture.registry.load().map(\.id), [fixture.canonicalID])
    let canonical = try #require(fixture.registry.account(id: fixture.canonicalID))
    #expect(try ClaudeCredentialsStore.parse(canonical.payload).accessToken == "live-access")
    expectNoDifference(
      canonical.claudeAccountIdentity,
      ClaudeAccountIdentity(
        accountID: "account",
        email: "same@example.com",
        organizationID: "organization"
      )
    )
  }

  @Test func rejectedCanonicalGenerationKeepsEveryFallbackAndReference() async throws {
    let fixture = try makeDuplicateHealReloadFixture(
      canonicalAlreadyLive: false,
      allowsCanonicalRefresh: false
    )

    await fixture.store.reloadAccounts()

    #expect(Set(fixture.registry.load().map(\.id)) == [fixture.canonicalID, "claude:redundant"])
    let canonical = try #require(fixture.registry.account(id: fixture.canonicalID))
    #expect(try ClaudeCredentialsStore.parse(canonical.payload).accessToken == "canonical-dead-access")
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(
      id: "claude:redundant"
    ))
    #expect(try fixture.monitoringStore.load()[.claude]?.contains(where: {
      $0.credentialSource == .quotariRegistry(id: "claude:redundant")
    }) == true)
  }

  @Test func emailOnlyLegacyIdentityCannotBridgeDifferentUUIDAccounts() {
    let first = ClaudeAccountIdentity(accountID: "account-a", email: "same@example.com", organizationID: "org")
    let legacy = ClaudeAccountIdentity(email: "same@example.com", organizationID: "org")
    let second = ClaudeAccountIdentity(accountID: "account-b", email: "same@example.com", organizationID: "org")

    #expect(!first.identifiesSameAccount(as: legacy))
    #expect(!legacy.identifiesSameAccount(as: second))
    #expect(!first.identifiesSameAccount(as: second))
    #expect(!legacy.isStrong)
  }

  @Test func plansCleanupOnlyAfterRefreshingTheCanonicalRow() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:dead-old", token: "dead-old", capturedAt: Date(timeIntervalSince1970: 100)),
        SavedRowSpec(id: "claude:dead-new", token: "dead-new", capturedAt: Date(timeIntervalSince1970: 200)),
      ],
      reauthenticationRequiredIDs: ["claude:dead-old", "claude:dead-new"]
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    let remaining = fixture.registry.load().map(\.id)
    #expect(remaining == ["claude:dead-old", "claude:dead-new"])
    guard case let .refreshClaude(id, _, _, _, redundant) = plans[fixture.candidate.id] else {
      Issue.record("Expected refreshClaude, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
    #expect(id == "claude:dead-new")
    #expect(redundant.map(\.id) == ["claude:dead-old"])
  }

  @Test func keepsBlockedWhenDuplicateSavedRowsAreBothPlausiblyAlive() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(
          id: "claude:alive-one",
          token: "alive-one",
          capturedAt: Date(timeIntervalSince1970: 100),
          expiresAt: Date().addingTimeInterval(3600)
        ),
        SavedRowSpec(
          id: "claude:alive-two",
          token: "alive-two",
          capturedAt: Date(timeIntervalSince1970: 200),
          expiresAt: Date().addingTimeInterval(3600)
        ),
      ],
      reauthenticationRequiredIDs: []
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    #expect(Set(fixture.registry.load().map(\.id)) == ["claude:alive-one", "claude:alive-two"])
    guard case let .blocked(message) = plans[fixture.candidate.id] else {
      Issue.record("Expected blocked, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
    #expect(message == "Multiple saved Claude accounts have the same verified profile.")
  }

  @Test func keepsExpiredDuplicateWithoutInvalidGrantProof() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:dead", token: "dead", capturedAt: Date(timeIntervalSince1970: 200)),
        SavedRowSpec(id: "claude:transient", token: "transient", capturedAt: Date(timeIntervalSince1970: 100)),
      ],
      reauthenticationRequiredIDs: ["claude:dead"],
      transientFailureIDs: ["claude:transient"]
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    // Only the invalid-grant row is removable; the transiently failing row may
    // still hold a working refresh token and becomes the canonical target.
    #expect(fixture.registry.load().map(\.id) == ["claude:transient"])
    guard case let .refreshClaude(id, _, _, _, _) = plans[fixture.candidate.id] else {
      Issue.record("Expected refreshClaude, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
    #expect(id == "claude:transient")
  }

  @Test func keepsBothExpiredDuplicatesOnTransientFailures() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:first", token: "first", capturedAt: Date(timeIntervalSince1970: 100)),
        SavedRowSpec(id: "claude:second", token: "second", capturedAt: Date(timeIntervalSince1970: 200)),
      ],
      reauthenticationRequiredIDs: [],
      transientFailureIDs: ["claude:first", "claude:second"]
    )

    let plans = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    #expect(Set(fixture.registry.load().map(\.id)) == ["claude:first", "claude:second"])
    guard case .blocked = plans[fixture.candidate.id] else {
      Issue.record("Expected blocked, got \(String(describing: plans[fixture.candidate.id]))")
      return
    }
  }

  @Test func planningDoesNotDropPinnedProfileBeforeCanonicalWrite() async throws {
    let fixture = try makeDuplicateHealFixture(
      savedRows: [
        SavedRowSpec(id: "claude:dead-old", token: "dead-old", capturedAt: Date(timeIntervalSince1970: 100)),
        SavedRowSpec(id: "claude:dead-new", token: "dead-new", capturedAt: Date(timeIntervalSince1970: 200)),
      ],
      reauthenticationRequiredIDs: ["claude:dead-old", "claude:dead-new"]
    )
    let removedSavedID = ProviderAccount.id(
      provider: .claude,
      source: .quotariRegistry(id: "claude:dead-old")
    )
    #expect(fixture.store.claudeProfiles[removedSavedID] != nil)

    _ = await fixture.store.automaticCapturePlans(
      for: [fixture.candidate],
      among: [fixture.candidate],
      provider: .claude
    )

    #expect(fixture.store.claudeProfiles[removedSavedID] != nil)
  }

  private func expectDuplicateRows(_ fixture: DuplicateHealReloadFixture) {
    expectNoDifference(
      fixture.registry.load().map(\.id).sorted(),
      [fixture.canonicalID, fixture.redundantID].sorted()
    )
  }

  private func blockDuplicateHealPersistenceWrites(at url: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
      try fileManager.removeItem(at: url)
    }
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
  }

  private func restoreDuplicateHealPersistenceWrites(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}
