import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeAutomaticRecoveryTests {
  @Test func reloadRepairsTheCLIAndCollapsesTheSelectedSavedCopy() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture()

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    let accounts = try #require(fixture.store.accounts[.claude])
    #expect(accounts.count == 1)
    #expect(accounts.first?.credentialSource == fixture.source)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
    #expect(fixture.store.capturedEquivalents[fixture.liveID]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.registry.load().count == 1)
    #expect(!fixture.store.automaticallyCapturingProviders.contains(.claude))
  }

  @Test func periodicRefreshRepairsSavedOnlyMonitoringAfterClaudeExits() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true)
    fixture.activity.isActive = true
    await fixture.store.reloadAccounts()
    #expect(fixture.store.accounts[.claude]?.allSatisfy(\.credentialSource.isCaptured) == true)
    #expect(fixture.store.reconciledSelectionOrigins.isEmpty)
    #expect(fixture.store.activeCLIAccount(for: .claude) == nil)

    fixture.activity.isActive = false
    await fixture.store.refresh()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.activeCLIAccount(for: .claude)?.credentialSource == fixture.source)
    #expect(fixture.store.accounts[.claude]?.count == 1)
  }

  @Test(arguments: [false, true])
  func periodicRecoveryRetriesAfterKeychainReadsBecomeAvailable(discoveredBeforeLock: Bool) async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true)
    fixture.store.selectAccount(nil, for: .claude)
    if discoveredBeforeLock {
      await fixture.store.reloadAccounts()
      #expect(fixture.store.accounts[.claude]?.isEmpty == false)
    }
    fixture.keychain.isLocked = true
    await fixture.store.reloadAccounts()
    #expect(fixture.store.accounts[.claude]?.isEmpty == true)
    #expect(fixture.store.monitoredAccounts[.claude]?.isEmpty == true)
    #expect(fixture.store.reconciledSelectionOrigins.isEmpty)

    fixture.keychain.isLocked = false
    fixture.store.beginRefresh(interaction: .background)
    await fixture.store.inFlightRefresh?.value

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.accounts[.claude]?.count == 1)
    #expect(fixture.store.monitoredAccounts[.claude]?.count == 1)
  }

  @Test func emptyDiscoveryDoesNotRecoverWhileClaudeMonitoringIsDisabled() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true)
    fixture.store.selectAccount(nil, for: .claude)
    fixture.keychain.isLocked = true
    await fixture.store.reloadAccounts()
    fixture.store.setProviderEnabled(.claude, enabled: false)
    let original = fixture.slot.value

    fixture.keychain.isLocked = false
    fixture.store.beginRefresh(interaction: .background)
    await fixture.store.inFlightRefresh?.value

    #expect(fixture.slot.value == original)
    #expect(fixture.store.accounts[.claude]?.isEmpty == true)
  }

  @Test(arguments: [false, true])
  func reloadKeepsTheSelectedLiveAccountAfterRecovery(selectMirror: Bool) async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: selectMirror ? .mirror : .live)
    let previousScope = try #require(fixture.store.selectedAccounts[.claude]?.credentialScopeID)
    #expect(fixture.store.reconciledSelectionOrigins[.claude] == nil)

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    let selected = try #require(fixture.store.selectedAccounts[.claude])
    #expect(selected.credentialSource == fixture.source)
    #expect(selected.credentialScopeID != previousScope)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.accounts[.claude]?.count == 1)
  }

  @Test func periodicRecoveryFinishesAPartialMirrorAfterClaudeExits() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .mirror)
    fixture.activity.startsAfterCredentialWrite = true
    await fixture.store.reloadAccounts()
    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "old-access")
    let fileID = ProviderAccount.id(provider: .claude, source: .claudeCredentialsFile(path: fixture.fileURL.path))
    let persistedProfiles = ClaudeProfileStore(url: fixture.directory.url.appendingPathComponent("profiles.json"))
      .load()
    #expect(persistedProfiles[fileID]?.fingerprint == ProviderCredentialIdentity.fingerprint(of: "old-access"))
    fixture.store.claudeProfiles[fixture.liveID] = fixture.store.claudeProfiles[fixture.saved.providerAccount.id]
    fixture.store.beginRefresh(interaction: .background)
    await fixture.store.inFlightRefresh?.value
    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "old-access")

    fixture.activity.startsAfterCredentialWrite = false
    fixture.activity.isActive = false
    fixture.store.beginRefresh(interaction: .background)
    await fixture.store.inFlightRefresh?.value

    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "saved-access")
    #expect(fixture.store.accounts[.claude]?.count == 1)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
  }

  @Test func recoveryDoesNotAdoptASelectionForAnUnrelatedTokenInTheSameSlot() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .live, selectedToken: "unrelated-access")

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude] == nil)
    #expect(fixture.store.reconciledSelectionOrigins[.claude] == nil)
  }

  @Test func recoveryContinuesTheCredentialTransitionCompletedBeforeReload() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .live, selectedToken: "earlier-access")
    let selectedScope = try #require(fixture.store.selectedAccounts[.claude]?.credentialScopeID)
    let live = ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: nil,
      credentialSource: fixture.source, credentialIdentity: "old-access"
    )
    fixture.store.completedCredentialTransitions[.claude] = [selectedScope: [live.credentialScopeID]]

    await fixture.store.reloadAccounts()

    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
  }

  @Test func automaticRecoveryNeverFollowsAnUnrelatedDashboardSelection() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture()
    let other = CapturedAccount(
      id: "claude:other", provider: .claude, displayName: "Other", detail: nil,
      capturedAt: fixture.now, origin: fixture.source,
      payload: claudePayload(
        accessToken: "other-access",
        refreshToken: "other-refresh",
        expiresAt: fixture.now.addingTimeInterval(3600)
      ),
      claudeAccountIdentity: ClaudeAccountIdentity(accountID: "other", organizationID: "other-org")
    )
    try fixture.registry.save(other)
    fixture.store.selectAccount(other.providerAccount, for: .claude)

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude]?.id == other.providerAccount.id)
    #expect(fixture.registry.account(id: other.id) == other)
  }
}
