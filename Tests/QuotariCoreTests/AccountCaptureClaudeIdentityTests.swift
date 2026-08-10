import Foundation
@testable import QuotariCore
import Testing

struct AccountCaptureClaudeIdentityTests {
  @Test func verifiedClaudeCapturePreservesTheMissingRefreshTokenError() throws {
    let payload = Data(#"{"claudeAiOauth":{"accessToken":"c-tok"}}"#.utf8)
    let keychain = InMemoryKeychain()
    let registry = CapturedAccountStore(
      keychain: keychain.store,
      service: "Test-Claude-Identity-\(UUID().uuidString)"
    )
    let service = AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload }
    )
    let account = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: "Claude Code-credentials")
    )

    #expect(throws: AccountCaptureError.noRefreshToken) {
      try service.captureClaudeAccount(
        account,
        expectedAccessTokenFingerprint: ProviderCredentialIdentity.fingerprint(of: "c-tok"),
        profile: ClaudeProfile(accountID: "acct", organizationID: "org"),
        now: Date(timeIntervalSince1970: 1000)
      )
    }
  }
}
