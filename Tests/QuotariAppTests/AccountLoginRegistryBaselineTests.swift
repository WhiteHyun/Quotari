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
    baseline.recordClaudeRotation(keychainPayload: rotated, accountState: nil, accountID: "previous")
    baseline.recordClaudeRotation(keychainPayload: browserLogin, accountState: nil, accountID: "new")

    #expect(try #require(baseline.claudeKeychainSnapshot).payload == rotated)
  }

  @Test func signedOutRecoveryRemainsSignedOutWhenTheBrowserCredentialAppears() throws {
    let baseline = AccountLoginRegistryBaseline([])

    baseline.recordClaudeLogin(keychainPayload: nil, accountState: nil, accountID: nil)
    baseline.recordClaudeRotation(
      keychainPayload: Data("browser-login".utf8),
      accountState: nil,
      accountID: "new"
    )

    #expect(try #require(baseline.claudeKeychainSnapshot).payload == nil)
  }
}
