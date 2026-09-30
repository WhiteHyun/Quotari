import Foundation
@testable import QuotariCore
import Testing

struct ClaudeAutomaticRecoveryStateTests {
  @Test(arguments: ["installed", "replaced", "unreadable", "identity-changed"])
  func partialRecoveryOnlyReportsVerifiedInstalledScopes(scenario: String) throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    try FileManager.default.createDirectory(
      at: fixture.fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try #require(fixture.slot.value).write(to: fixture.fileURL)
    let (slot, stateURL) = (fixture.slot, fixture.stateURL)
    let readFailure = KeychainSlot(nil)
    let service = fixture.service(active: { _ in
      guard let payload = slot.value, try ClaudeCredentialsStore.parse(payload).accessToken == "saved-access"
      else { return [] }
      switch scenario {
      case "replaced": slot.value = Data(#"{"claudeAiOauth":{"accessToken":"external"}}"#.utf8)
      case "unreadable": readFailure.value = Data()
      case "identity-changed": try Data(#"{"oauthAccount":{"accountUuid":"external"}}"#.utf8).write(to: stateURL)
      default: break
      }
      return ["claude"]
    }, read: { _ in
      guard readFailure.value == nil else { throw CocoaError(.fileReadNoPermission) }
      return slot.value
    })

    do {
      _ = try service.recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now)
      Issue.record("Expected a partial recovery")
    } catch let failure as ClaudeCLIRecoveryFailure {
      if scenario == "installed" {
        let old = recoveryScope(source: fixture.source, token: "old-access")
        let new = recoveryScope(source: fixture.source, token: "saved-access")
        #expect(failure.credentialTransitions == [old: new])
        #expect(failure.credentialTransitions[recoveryScope(source: fixture.fileSource, token: "old-access")] == nil)
      } else {
        #expect(failure.credentialTransitions.isEmpty)
      }
    }
  }

  @Test func recoveryPreservesTheAccountStateSymlinkAndTarget() throws {
    let fixture = try ClaudeAutomaticRecoveryFixture()
    let managed = fixture.home.appendingPathComponent("managed-claude.json")
    let original = try Data(contentsOf: fixture.stateURL)
    try FileManager.default.moveItem(at: fixture.stateURL, to: managed)
    try FileManager.default.createSymbolicLink(at: fixture.stateURL, withDestinationURL: managed)
    let attributes = try FileManager.default.attributesOfItem(atPath: managed.path)

    #expect(try fixture.service().recoverClaudeCLIIfNeeded(profiles: fixture.profiles, now: fixture.now) != nil)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.stateURL.path) == managed.path)
    #expect(try Data(contentsOf: managed) == original)
    let after = try FileManager.default.attributesOfItem(atPath: managed.path)
    #expect(after[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber)
    #expect(try ClaudeCredentialsStore.parse(#require(fixture.slot.value)).accessToken == "saved-access")
  }
}

private func recoveryScope(source: ProviderCredentialSource, token: String) -> String {
  ProviderAccount(
    provider: .claude, displayName: "Claude", detail: nil, credentialSource: source, credentialIdentity: token
  ).credentialScopeID
}
