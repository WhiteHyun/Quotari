import Foundation
@testable import QuotariCore
import Testing

struct ClaudeSelectionFingerprintTests {
  @Test func selectionPersistsProfileBindingWithoutPersistingTheToken() throws {
    let account = makeAccount()
    let encoded = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(ProviderAccount.self, from: encoded)

    #expect(decoded == account)
    #expect(decoded.claudeAccessTokenFingerprint == ProviderCredentialIdentity.fingerprint(of: "secret-access"))
    let json = try #require(String(data: encoded, encoding: .utf8))
    #expect(!json.contains("secret-access"))
  }

  @Test func legacySelectionKeepsItsScopeWithoutInventingProfileProof() throws {
    let account = makeAccount()
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
    object.removeValue(forKey: "claudeAccessTokenFingerprint")
    let decoded = try JSONDecoder().decode(ProviderAccount.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.id == account.id)
    #expect(decoded.credentialScopeID == account.credentialScopeID)
    #expect(decoded.claudeAccessTokenFingerprint == nil)
  }

  private func makeAccount() -> ProviderAccount {
    ProviderAccount(
      provider: .claude, displayName: "Claude", detail: nil,
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      credentialIdentity: "secret-access"
    )
  }
}
