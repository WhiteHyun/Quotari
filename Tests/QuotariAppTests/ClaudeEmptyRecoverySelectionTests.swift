import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ClaudeEmptyRecoverySelectionTests {
  @Test(arguments: [false, true])
  func emptySlotRecoveryPreservesAVerifiedDirectSelection(selectMirror: Bool) async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true, selection: selectMirror ? .mirror : .live)
    let selected = try #require(fixture.store.selectedAccounts[.claude])
    #expect(fixture.store.reconciledSelectionOrigins[.claude] == nil)

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    let recovered = try #require(fixture.store.selectedAccounts[.claude])
    #expect(recovered.credentialSource == fixture.source)
    #expect(recovered.credentialScopeID != selected.credentialScopeID)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.accountSelectionStore.load()[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.accounts[.claude]?.count == 1)
  }

  @Test(arguments: [
    "unrelated-token",
    "different-account",
    "different-organization",
    "unverified",
    "legacy",
    "conflicting",
  ])
  func emptySlotRecoveryDoesNotAdoptAnUnprovenSelection(scenario: String) async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(
      empty: true, selection: .live,
      selectedToken: scenario == "unrelated-token" ? "unrelated-access" : "old-access"
    )
    switch scenario {
    case "different-account": fixture.store.claudeProfiles[fixture.liveID]?.accountID = "other"
    case "different-organization": fixture.store.claudeProfiles[fixture.liveID]?.organizationID = "other"
    case "unverified": fixture.store.claudeProfiles[fixture.liveID]?.fingerprint = nil
    case "legacy":
      let selected = try #require(fixture.store.selectedAccounts[.claude])
      var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as? [String: Any])
      object.removeValue(forKey: "claudeAccessTokenFingerprint")
      let legacy = try JSONDecoder().decode(
        ProviderAccount.self, from: JSONSerialization.data(withJSONObject: object)
      )
      fixture.store.selectAccount(legacy, for: .claude)
    case "conflicting":
      var conflict = try #require(fixture.store.claudeProfiles[fixture.liveID])
      conflict.accountID = "other"
      fixture.store.claudeProfiles["conflict"] = conflict
    default: break
    }

    await fixture.store.reloadAccounts()

    // Terminal identity still permits restoring the CLI, but cannot prove
    // that this historical dashboard selection belongs to the same account.
    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude] == nil)
    #expect(fixture.store.accountSelectionStore.load()[.claude] == nil)
  }

  @Test(arguments: [false, true])
  func partialEmptySlotRecoveryKeepsSelectionThroughTheMirrorRetry(selectMirror: Bool) async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true, selection: selectMirror ? .mirror : .live)
    try FileManager.default.createDirectory(
      at: fixture.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try fixture.slot.value.write(to: fixture.fileURL)
    fixture.activity.startsAfterCredentialWrite = true

    await fixture.store.reloadAccounts()

    #expect(fixture.store.selectedAccounts[.claude] != nil)
    if !selectMirror {
      #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    }
    fixture.store.claudeProfiles[fixture.liveID] = fixture.store.claudeProfiles[fixture.saved.providerAccount.id]
    fixture.activity.startsAfterCredentialWrite = false
    fixture.activity.isActive = false
    fixture.store.beginRefresh(interaction: .background)
    await fixture.store.inFlightRefresh?.value

    #expect(try ClaudeCredentialsStore.parse(Data(contentsOf: fixture.fileURL)).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.accounts[.claude]?.count == 1)
  }

  @Test func historicalProofCannotBridgeANonemptyReplacement() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(selection: .live, selectedToken: "earlier-access")
    fixture.store.claudeProfiles["historical"] = fixture.store.claudeProfiles[fixture.liveID]?
      .verified(for: ProviderCredentialIdentity.fingerprint(of: "earlier-access"))

    await fixture.store.reloadAccounts()

    #expect(try ClaudeCredentialsStore.parse(fixture.slot.value).accessToken == "saved-access")
    #expect(fixture.store.selectedAccounts[.claude] == nil)
  }

  @Test func emptySlotSelectionSurvivesWaitingForClaudeToExit() async throws {
    let fixture = try AutomaticCLIRecoveryAppFixture(empty: true, selection: .live)
    let selected = fixture.store.selectedAccounts[.claude]
    fixture.activity.isActive = true
    await fixture.store.reloadAccounts()
    #expect(fixture.store.selectedAccounts[.claude] == selected)

    fixture.activity.isActive = false
    fixture.store.beginRefresh(interaction: .background)
    await fixture.store.inFlightRefresh?.value

    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == fixture.saved.providerAccount.id)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == fixture.source)
  }
}
