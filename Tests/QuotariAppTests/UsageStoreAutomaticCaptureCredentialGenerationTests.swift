import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ClaudeCredentialGenerationTests {
  @Test func invalidGrantDoesNotCondemnAReplacementCredentialGeneration() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let captured = credentialGenerationTestAccount()
    try registry.save(captured)
    let replacementPayload = claudePayload(
      accessToken: "replacement-access",
      refreshToken: "replacement-refresh",
      expiresAt: Date(timeIntervalSince1970: 0)
    )
    let strategy = RotatingInvalidGrantStrategy(
      registry: registry,
      registryID: captured.id,
      replacementPayload: replacementPayload
    )
    let store = UsageStore.isolatedForTesting(
      providers: [credentialGenerationDescriptor(strategy: strategy)],
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      claudeCredentialLoader: { source in
        guard case let .quotariRegistry(id) = source else { return nil }
        return registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
      },
      startsAutomatically: false
    )

    let resolution = await store.resolvedSavedClaudeProfiles([captured])
    let resolved = try #require(resolution.profiles.first)

    #expect(!resolved.requiresReauthentication)
    #expect(
      resolved.profile.fingerprint
        == ProviderCredentialIdentity.fingerprint(of: "replacement-access")
    )
    let persisted = try #require(registry.account(id: captured.id))
    #expect(try ClaudeCredentialsStore.parse(persisted.payload).refreshToken == "replacement-refresh")
  }
}

private func credentialGenerationTestAccount() -> CapturedAccount {
  CapturedAccount(
    id: "claude:rotating",
    provider: .claude,
    displayName: "Claude Code",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 100),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: claudePayload(
      accessToken: "rejected-access",
      refreshToken: "rejected-refresh",
      expiresAt: Date(timeIntervalSince1970: 0)
    ),
    claudeAccountIdentity: ClaudeAccountIdentity(
      accountID: "account",
      email: "person@example.com",
      organizationID: "organization"
    )
  )
}

private func credentialGenerationDescriptor(
  strategy: some ProviderFetchStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

private struct RotatingInvalidGrantStrategy: ProviderFetchStrategy {
  let id = "invalid-grant-after-credential-replacement"
  let kind = ProviderFetchKind.oauth
  let registry: CapturedAccountStore
  let registryID: String
  let replacementPayload: Data

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    try registry.updatePayload(id: registryID) { _ in replacementPayload }
    throw ClaudeTokenRefreshError.reauthenticationRequired
  }
}
