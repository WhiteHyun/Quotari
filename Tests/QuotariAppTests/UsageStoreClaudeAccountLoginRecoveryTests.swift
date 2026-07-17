import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ClaudeAccountLoginRecoveryTests {
  @Test func loginDoesNotStealCredentialGateAcquiredDuringPreservation() async throws {
    let context = try makeClaudeLoginContext()
    let profiles = AccountLoginGatedClaudeProfileFetcher(
      gatedAccessToken: "current-access",
      profiles: [
        "current-access": ClaudeProfile(accountID: "account-current", email: "current@example.com"),
      ]
    )
    let loginCalled = ClaudeLoginBooleanBox()
    let login = AccountLoginService { provider in
      loginCalled.value = true
      throw AccountLoginError.credentialUnavailable(provider)
    }
    let store = context.makeStore(login: login, profileFetcher: profiles)
    let loginTask = Task { await store.addAccount(for: .claude) }
    await profiles.waitUntilRequestStarts()

    store.isSwitching = true
    await profiles.resume()
    await loginTask.value

    #expect(!loginCalled.value)
    #expect(store.isSwitching)
    #expect(store.accountLoginErrors[.claude]?.contains("Another account switch started") == true)
    store.isSwitching = false
  }

  @Test func failedFirstLoginRestoresTheSignedOutState() async throws {
    let context = try makeClaudeLoginContext(source: .none)
    let rejectedPayload = claudePayload(
      accessToken: "unverified-access",
      refreshToken: "unverified-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        nil
      )
      credentialMutation?()
      context.liveCredential.value = rejectedPayload
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: rejectedPayload
      )
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    #expect(context.liveCredential.value == nil)
    let saved = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    #expect(saved.count == 1)
    #expect(saved.first?.accessToken == "unverified-access")
    #expect(store.activeCLIAccounts[.claude] == nil)
    #expect(store.accountLoginErrors[.claude]?.contains("couldn’t verify the new Claude account") == true)
  }

  @Test func unrenewableLoginResultRestoresThePreviousCredentialGeneration() async throws {
    let context = try makeClaudeLoginContext()
    let rejectedPayload = Data(#"{"claudeAiOauth":{"accessToken":"unrenewable"}}"#.utf8)
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      credentialMutation?()
      context.liveCredential.value = rejectedPayload
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: rejectedPayload
      )
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restoredPayload = try #require(context.liveCredential.value)
    let restored = try ClaudeCredentialsStore.parse(restoredPayload)
    #expect(restored.accessToken == "current-access")
    #expect(context.registry.load().count == 1)
    #expect(store.accountLoginErrors[.claude] != nil)
    #expect(store.accountLoginErrors[.claude]?.contains("recovery error") == false)
  }

  @Test func failedLoginRestoresKeychainAndClaudeAccountStateTogether() async throws {
    let context = try makeClaudeLoginContext()
    let accountStateURL = context.directory.url.appendingPathComponent(".claude.json")
    let previousAccountState = Data(
      #"{"theme":"dark","oauthAccount":{"accountUuid":"account-current","emailAddress":"current@example.com"}}"#.utf8
    )
    try previousAccountState.write(to: accountStateURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: accountStateURL.path)
    let rejectedAccountState = Data(
      #"{"theme":"light","oauthAccount":{"accountUuid":"account-interrupted","emailAddress":"interrupted@example.com"}}"#
        .utf8
    )
    let rejectedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      credentialMutation?()
      context.liveCredential.value = rejectedPayload
      try rejectedAccountState.write(to: accountStateURL)
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restored = try ClaudeCredentialsStore.parse(#require(context.liveCredential.value))
    #expect(restored.accessToken == "current-access")
    #expect(try Data(contentsOf: accountStateURL) == previousAccountState)
    let savedRejected = try #require(context.registry.load().first(where: { account in
      (try? ClaudeCredentialsStore.parse(account.payload).accessToken) == "interrupted-access"
    }))
    // The failed login never verified that the rejected Keychain token and
    // account-state file belonged to the same account.
    #expect(savedRejected.claudeOAuthAccount == nil)
    #expect(store.accountLoginErrors[.claude]?.contains("status 9") == true)
  }

  @Test func signedOutOverwriteBoundarySupersedesThePreflightAccount() async throws {
    let context = try makeClaudeLoginContext()
    let rejectedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      context.liveCredential.value = nil
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        nil
      )
      credentialMutation?()
      context.liveCredential.value = rejectedPayload
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    #expect(context.liveCredential.value == nil)
    let saved = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    #expect(saved.count == 2)
    #expect(saved.contains(where: { $0.accessToken == "current-access" }))
    #expect(saved.contains(where: { $0.accessToken == "interrupted-access" }))
    #expect(store.accountLoginErrors[.claude]?.contains("status 9") == true)
  }

  @Test func preflightFailureDoesNotAttemptCredentialRestoration() async throws {
    let context = try makeClaudeLoginContext()
    let login = AccountLoginService { provider in
      throw AccountLoginError.cliStillRunning(provider, processes: ["claude (PID 42)"])
    }
    let switcher = context.makeSwitcher { _ in ["claude (PID 42)"] }
    let store = context.makeStore(login: login, accountSwitch: switcher)

    await store.addAccount(for: .claude)

    #expect(store.accountLoginErrors[.claude]?.contains("Close Claude Code") == true)
    #expect(store.accountLoginErrors[.claude]?.contains("recovery error") == false)
  }

  @Test func organizationOnlyProfileDoesNotBecomeASeparateAccountIdentity() async throws {
    let context = try makeClaudeLoginContext()
    let incompleteIdentityPayload = claudePayload(
      accessToken: "organization-only-access",
      refreshToken: "organization-only-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      credentialMutation?()
      context.liveCredential.value = incompleteIdentityPayload
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: incompleteIdentityPayload
      )
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restored = try ClaudeCredentialsStore.parse(#require(context.liveCredential.value))
    #expect(restored.accessToken == "current-access")
    #expect(store.accountLoginErrors[.claude]?.contains("couldn’t verify the new Claude account") == true)
  }

  @Test func organizationOnlyCachedProfileIsRefetchedBeforeReauthenticationMatching() async throws {
    let context = try makeClaudeLoginContext()
    let currentPayload = try #require(context.liveCredential.value)
    let captured = try context.capture.captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: currentPayload,
      now: Date()
    )
    let current = try #require(captured)
    let currentCredentials = try ClaudeCredentialsStore.parse(currentPayload)
    let reauthenticated = claudePayload(
      accessToken: "reauthenticated-access",
      refreshToken: "reauthenticated-refresh"
    )
    let login = AccountLoginService { provider in
      context.liveCredential.value = reauthenticated
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: reauthenticated
      )
    }
    let store = context.makeStore(login: login)
    store.claudeProfiles[current.providerAccount.id] = ClaudeProfile(
      organizationName: "Cached Organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: currentCredentials.accessToken)
    )

    await store.addAccount(for: .claude)

    let saved = try #require(context.registry.account(id: current.id))
    let savedCredentials = try ClaudeCredentialsStore.parse(saved.payload)
    #expect(context.registry.load().count == 1)
    #expect(savedCredentials.accessToken == "reauthenticated-access")
    #expect(store.accountLoginErrors[.claude] == nil)
  }
}
