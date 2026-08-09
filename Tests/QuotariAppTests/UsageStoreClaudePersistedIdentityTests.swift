import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudePersistedIdentityTests {
  @Test func weakProfileCacheCannotDowngradePersistedStrongIdentity() async throws {
    let payload = claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    let identity = ClaudeAccountIdentity(
      accountID: "account",
      email: "saved@example.com",
      organizationID: "organization"
    )
    let captured = CapturedAccount(
      id: "claude:legacy-row",
      provider: .claude,
      displayName: "Claude account",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 1),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: payload,
      claudeAccountIdentity: identity
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(captured)
    let profileStore = ClaudeProfileStore.temporaryForTesting()
    try profileStore.save([
      captured.providerAccount.id: ClaudeProfile(
        accountID: "account",
        email: "saved@example.com",
        fingerprint: ProviderCredentialIdentity.fingerprint(of: "saved-access")
      ),
    ])
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      profileStore: profileStore,
      claudeCredentialLoader: { source in
        guard case let .quotariRegistry(id) = source else { return nil }
        return registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
      },
      startsAutomatically: false
    )

    let resolution = await store.resolvedSavedClaudeProfiles([captured])

    let resolved = try #require(resolution.profiles.first)
    #expect(resolved.profile.hasStrongAccountIdentity)
    #expect(resolved.profile.accountIdentity == identity)
    #expect(registry.account(id: captured.id)?.claudeAccountIdentity == identity)
  }
}
