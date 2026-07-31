import Foundation
@testable import Quotari
import Testing

struct AccountLoginRegistryBaselineTests {
  @Test func browserCredentialDoesNotReplaceTheLatestPreviousAccountRotation() throws {
    let baseline = AccountLoginRegistryBaseline([])
    let original = Data("original".utf8)
    let rotated = Data("rotated".utf8)
    let browserLogin = Data("browser-login".utf8)

    baseline.recordClaudeLogin(keychainPayload: original, accountState: nil, accountID: "previous")
    baseline.recordClaudeRotation(keychainPayload: rotated, accountID: "previous")
    baseline.recordClaudeRotation(keychainPayload: browserLogin, accountID: "new")

    #expect(try #require(baseline.claudeKeychainSnapshot).payload == rotated)
  }

  @Test func signedOutRecoveryRemainsSignedOutWhenTheBrowserCredentialAppears() throws {
    let baseline = AccountLoginRegistryBaseline([])

    baseline.recordClaudeLogin(keychainPayload: nil, accountState: nil, accountID: nil)
    baseline.recordClaudeRotation(
      keychainPayload: Data("browser-login".utf8),
      accountID: "new"
    )

    #expect(try #require(baseline.claudeKeychainSnapshot).payload == nil)
  }

  @Test func rotatedCredentialRetainsItsOriginalAccountState() throws {
    let baseline = AccountLoginRegistryBaseline([])
    let originalState = Data("previous-account-state".utf8)
    let rotated = Data("rotated".utf8)

    baseline.recordClaudeLogin(
      keychainPayload: Data("original".utf8),
      accountState: originalState,
      accountID: "previous"
    )
    baseline.recordClaudeRotation(keychainPayload: rotated, accountID: "previous")

    let snapshot = try #require(baseline.claudeKeychainSnapshot)
    #expect(snapshot.payload == rotated)
    #expect(snapshot.accountState == originalState)
  }
}
