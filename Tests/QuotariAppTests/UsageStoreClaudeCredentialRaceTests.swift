import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeCredentialRaceTests {
  @Test func observedRotationWithoutExpiryReplacesTheConsumedSavedGeneration() async throws {
    let context = try makeClaudeLoginContext()
    let originalPayload = try #require(context.liveCredential.value)
    let source = ProviderCredentialSource.claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    let captured = try context.capture.captureRawPayload(
      provider: .claude,
      origin: source,
      payload: originalPayload,
      now: .distantPast
    )
    let saved = try #require(captured)
    let store = context.makeStore(login: AccountLoginService())
    let baseline = try #require(try await store.accountRegistryBaseline(for: .claude))
    baseline.recordClaudeLogin(
      keychainPayload: originalPayload,
      accountState: nil,
      accountID: saved.id
    )
    let previousLogin = PreservedClaudeLogin(
      account: saved.providerAccount,
      profile: ClaudeProfile(
        accountID: "account-current",
        email: "current@example.com",
        organizationID: "organization-current"
      )
    )
    let rotatedPayload = claudePayload(
      accessToken: "rotated-current-access",
      refreshToken: "rotated-current-refresh"
    )
    context.liveCredential.value = rotatedPayload

    try await store.preserveCredentialDuringLogin(
      provider: .claude,
      source: source,
      payload: rotatedPayload,
      previousClaudeLogin: previousLogin,
      registryBaseline: baseline
    )

    let refreshed = try #require(context.registry.account(id: saved.id))
    let credentials = try ClaudeCredentialsStore.parse(refreshed.payload)
    #expect(credentials.accessToken == "rotated-current-access")
    #expect(credentials.refreshToken == "rotated-current-refresh")
  }

  @Test func lastMinuteRotationWithoutFreshnessEvidenceBlocksLogin() async throws {
    let context = try makeClaudeLoginContext()
    let rotatedPayload = claudePayload(
      accessToken: "rotated-current-access",
      refreshToken: "rotated-current-refresh"
    )
    let loginMutatedCredential = ClaudeLoginBooleanBox()
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      context.liveCredential.value = rotatedPayload
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        rotatedPayload
      )
      credentialMutation?()
      loginMutatedCredential.value = true
      throw AccountLoginError.credentialUnavailable(provider)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let savedCredentials = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    let liveCredential = try ClaudeCredentialsStore.parse(#require(context.liveCredential.value))
    #expect(!loginMutatedCredential.value)
    #expect(savedCredentials.count == 1)
    #expect(savedCredentials.first?.accessToken == "current-access")
    #expect(liveCredential.accessToken == "rotated-current-access")
    #expect(store.accountLoginErrors[.claude]?.contains("couldn’t preserve") == true)
  }

  @Test func credentialChangedImmediatelyBeforeLoginIsPreservedSeparately() async throws {
    let context = try makeClaudeLoginContext()
    let interveningPayload = claudePayload(
      accessToken: "intervening-access",
      refreshToken: "intervening-refresh"
    )
    let interruptedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(observedManagedOperation: { provider, _, preserve, mutation, observation in
      context.liveCredential.value = interveningPayload
      try await preserve?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        interveningPayload
      )
      mutation?()
      context.liveCredential.value = interruptedPayload
      observation?(context.loginObservation(keychainPayload: interruptedPayload))
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let savedCredentials = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    #expect(savedCredentials.count == 3)
    #expect(savedCredentials.contains(where: { $0.accessToken == "current-access" }))
    #expect(savedCredentials.contains(where: { $0.accessToken == "intervening-access" }))
    #expect(savedCredentials.contains(where: { $0.accessToken == "interrupted-access" }))
    let live = try ClaudeCredentialsStore.parse(#require(context.liveCredential.value))
    #expect(live.accessToken == "intervening-access")
  }
}
