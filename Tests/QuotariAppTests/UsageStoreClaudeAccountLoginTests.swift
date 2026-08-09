import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeAccountLoginTests {
  @Test func loginPreservesCurrentAccountAndSelectsNewLiveAccount() async throws {
    let context = try makeClaudeLoginContext()
    let addedPayload = claudePayload(accessToken: "added-access", refreshToken: "added-refresh")
    let login = AccountLoginService { provider in
      #expect(provider == .claude)
      #expect(context.registry.load().count == 1)
      context.liveCredential.value = addedPayload
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: addedPayload
      )
    }
    let store = context.makeStore(login: login)

    await store.addAccount(for: .claude)

    #expect(context.registry.load().count == 2)
    let live = try #require(store.activeCLIAccounts[.claude])
    #expect(store.selectedAccounts[.claude]?.id == live.id)
    #expect(store.monitoredAccounts[.claude]?.count == 2)
    #expect(store.monitoredAccounts[.claude]?.contains(where: { $0.id == live.id }) == true)
    #expect(store.capturedEquivalents[live.id] != nil)
    #expect(store.accountLoginErrors[.claude] == nil)
    #expect(store.accountLoginPhases[.claude] == nil)
    let accountState = try Data(contentsOf: context.directory.url.appendingPathComponent(".claude.json"))
    let extractedOAuthAccount = try ClaudeCodeAccountState.oauthAccount(from: accountState)
    let oauthAccount = try #require(extractedOAuthAccount)
    #expect(ClaudeCodeAccountState.matches(
      oauthAccount,
      profile: ClaudeProfile(accountID: "account-added", email: "added@example.com")
    ))
  }

  @Test func reauthenticatingTheCurrentAccountRefreshesItsSavedCopy() async throws {
    let context = try makeClaudeLoginContext()
    let preservedID = ClaudeLoginStringBox()
    let reauthenticated = claudePayload(
      accessToken: "reauthenticated-access",
      refreshToken: "reauthenticated-refresh"
    )
    let login = AccountLoginService { provider in
      #expect(context.registry.load().count == 1)
      preservedID.value = context.registry.load().first?.id
      context.liveCredential.value = reauthenticated
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: reauthenticated
      )
    }
    let store = context.makeStore(login: login)

    await store.addAccount(for: .claude)

    let saved = try #require(context.registry.load().first)
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    #expect(context.registry.load().count == 1)
    #expect(saved.id == preservedID.value)
    #expect(credentials.accessToken == "reauthenticated-access")
    #expect(credentials.refreshToken == "reauthenticated-refresh")
    #expect(saved.claudeAccountIdentity == ClaudeAccountIdentity(
      accountID: "account-current",
      email: "current@example.com",
      organizationID: "organization-current"
    ))
    #expect(store.monitoredAccounts[.claude]?.count == 1)
    #expect(store.accountLoginErrors[.claude] == nil)
  }

  @Test func reauthenticationConvergesPersistedAllDeadDuplicates() async throws {
    let context = try makeClaudeLoginContext(source: .none)
    let identity = ClaudeAccountIdentity(
      accountID: "account-current",
      email: "current@example.com",
      organizationID: "organization-current"
    )
    for (id, token, capturedAt) in [
      ("claude:dead-a", "dead-a", 200.0),
      ("claude:dead-b", "dead-b", 100.0),
    ] {
      try context.registry.save(CapturedAccount(
        id: id,
        provider: .claude,
        displayName: "Claude Code",
        detail: "Saved in Quotari",
        capturedAt: Date(timeIntervalSince1970: capturedAt),
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: claudePayload(
          accessToken: "\(token)-access",
          refreshToken: "\(token)-refresh",
          expiresAt: Date(timeIntervalSince1970: 0)
        ),
        claudeAccountIdentity: identity
      ))
    }
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
    let store = context.makeStore(
      login: login,
      descriptor: deadDuplicateClaudeLoginDescriptor(ids: ["claude:dead-a", "claude:dead-b"])
    )

    await store.addAccount(for: .claude)

    let saved = try #require(context.registry.load().first)
    #expect(context.registry.load().map(\.id) == ["claude:dead-a"])
    #expect(try ClaudeCredentialsStore.parse(saved.payload).accessToken == "reauthenticated-access")
    #expect(saved.claudeAccountIdentity == identity)
    #expect(store.accountLoginErrors[.claude] == nil)
  }

  @Test func successfulLoginRefreshesUsageAfterCredentialStabilizationDelay() async throws {
    let context = try makeClaudeLoginContext()
    let strategy = AutomaticCaptureCountingStrategy()
    let delay = PostCredentialRefreshGate()
    let requestsBeforeLogin = ClaudeLoginIntBox()
    let addedPayload = claudePayload(accessToken: "added-access", refreshToken: "added-refresh")
    let login = AccountLoginService { provider in
      requestsBeforeLogin.value = await strategy.requestCount
      context.liveCredential.value = addedPayload
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: addedPayload
      )
    }
    let store = context.makeStore(
      login: login,
      descriptor: countingClaudeDescriptor(strategy: strategy),
      postCredentialRefreshSleep: delay.sleep
    )

    await store.addAccount(for: .claude)
    await delay.waitUntilRequested()

    #expect(await strategy.requestCount == requestsBeforeLogin.value)
    #expect(await delay.requestedDurations == [.seconds(30)])

    await delay.resumeAll()
    await store.delayedCredentialRefreshTasks[.claude]?.task.value
    await store.selectionRefreshTasks[.claude]?.value

    #expect(await strategy.requestCount == requestsBeforeLogin.value + 1)
    #expect(store.accountLoginErrors[.claude] == nil)
  }

  @Test func reauthenticatingANoncurrentSavedAccountRefreshesItsExistingRow() async throws {
    let context = try makeClaudeLoginContext()
    let savedPayload = claudePayload(accessToken: "saved-other-access", refreshToken: "saved-other-refresh")
    let captured = try context.capture.captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: savedPayload,
      now: Date()
    )
    let existing = try #require(captured)
    let reauthenticated = claudePayload(
      accessToken: "saved-other-reauthenticated-access",
      refreshToken: "saved-other-reauthenticated-refresh"
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

    await store.addAccount(for: .claude)

    let saved = try #require(context.registry.account(id: existing.id))
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    #expect(context.registry.load().count == 2)
    #expect(saved.id == existing.id)
    #expect(credentials.accessToken == "saved-other-reauthenticated-access")
    #expect(credentials.refreshToken == "saved-other-reauthenticated-refresh")
    #expect(saved.claudeAccountIdentity == ClaudeAccountIdentity(
      accountID: "account-other",
      email: "other@example.com",
      organizationID: "organization-other"
    ))
    #expect(store.accountLoginErrors[.claude] == nil)
  }

  @Test func weakRotatedLoginDoesNotOverwriteTheStrongSavedAccount() async throws {
    let context = try makeClaudeLoginContext()
    let weakPayload = claudePayload(
      accessToken: "weak-rotated-access",
      refreshToken: "weak-rotated-refresh"
    )
    let login = AccountLoginService { provider in
      context.liveCredential.value = weakPayload
      return AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: weakPayload
      )
    }
    let profiles = TokenClaudeProfileFetcher(profiles: [
      "current-access": ClaudeProfile(
        accountID: "account-current",
        email: "current@example.com",
        organizationID: "organization-current"
      ),
      "weak-rotated-access": ClaudeProfile(
        accountID: "account-current",
        email: "current@example.com"
      ),
    ])
    let store = context.makeStore(login: login, profileFetcher: profiles)

    await store.addAccount(for: .claude)

    let saved = context.registry.load()
    #expect(saved.count == 2)
    let strong = try #require(saved.first(where: { $0.claudeAccountIdentity?.isStrong == true }))
    let weak = try #require(saved.first(where: { $0.claudeAccountIdentity?.isStrong != true }))
    let strongCredentials = try ClaudeCredentialsStore.parse(strong.payload)
    let weakCredentials = try ClaudeCredentialsStore.parse(weak.payload)
    #expect(strongCredentials.accessToken == "current-access")
    #expect(weakCredentials.accessToken == "weak-rotated-access")
    #expect(store.accountLoginErrors[.claude] == nil)

    await store.addAccount(for: .claude)

    #expect(context.registry.load().count == 2)
    #expect(store.captureErrors[.claude] == nil)
    #expect(store.captureWarnings[.claude] == UsageStore.weakClaudeIdentityDuplicateMessage)
    #expect(store.accountLoginErrors[.claude] == nil)
  }
}

@MainActor
struct UsageStoreClaudeAccountLoginFailureTests {
  @Test func failedLoginRetainsTheWrittenCredentialAndRestoresThePreservedCLISlot() async throws {
    let context = try makeClaudeLoginContext()
    let interruptedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(observedManagedOperation: { provider, _, preserve, mutation, observation in
      try await preserve?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      mutation?()
      context.liveCredential.value = interruptedPayload
      observation?(context.loginObservation(keychainPayload: interruptedPayload))
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restoredPayload = try #require(context.liveCredential.value)
    let restored = try ClaudeCredentialsStore.parse(restoredPayload)
    let savedCredentials = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    #expect(restored.accessToken == "current-access")
    #expect(savedCredentials.count == 2)
    #expect(savedCredentials.contains(where: { $0.accessToken == "interrupted-access" }))
    #expect(store.accountLoginErrors[.claude]?.contains("status 9") == true)
    #expect(store.accountLoginErrors[.claude]?.contains("also couldn’t restore") == false)
    #expect(store.accountLoginPhases[.claude] == nil)
  }

  @Test func failedIdentityVerificationRetainsThePotentiallyRotatedCredentialBackup() async throws {
    let context = try makeClaudeLoginContext()
    let rejectedPayload = claudePayload(
      accessToken: "unverified-access",
      refreshToken: "unverified-refresh"
    )
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
        payload: rejectedPayload,
        claudeLoginObservation: context.loginObservation(keychainPayload: rejectedPayload)
      )
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restoredPayload = try #require(context.liveCredential.value)
    let restored = try ClaudeCredentialsStore.parse(restoredPayload)
    let savedCredentials = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    #expect(restored.accessToken == "current-access")
    #expect(savedCredentials.count == 2)
    #expect(savedCredentials.contains(where: { $0.accessToken == "unverified-access" }))
    #expect(store.accountLoginErrors[.claude]?.contains("couldn’t verify the new Claude account") == true)
  }

  @Test func failedLoginPreservesAnIndependentDashboardSelection() async throws {
    let context = try makeClaudeLoginContext()
    let selectedPayload = claudePayload(
      accessToken: "saved-other-access",
      refreshToken: "saved-other-refresh"
    )
    let capturedSelection = try context.capture.captureRawPayload(
      provider: .claude,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: selectedPayload,
      now: Date()
    )
    let selectedCapture = try #require(capturedSelection)
    let interruptedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(observedManagedOperation: { provider, _, preserve, mutation, observation in
      try await preserve?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      mutation?()
      context.liveCredential.value = interruptedPayload
      observation?(context.loginObservation(keychainPayload: interruptedPayload))
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())
    await store.reloadAccounts()
    let selectedAccount = try #require(store.accounts[.claude]?.first(where: {
      $0.id == selectedCapture.providerAccount.id
    }))
    store.selectAccount(selectedAccount, for: .claude)

    await store.addAccount(for: .claude)

    let restoredPayload = try #require(context.liveCredential.value)
    let restored = try ClaudeCredentialsStore.parse(restoredPayload)
    #expect(store.persistableSelections()[.claude]?.id == selectedCapture.providerAccount.id)
    #expect(restored.accessToken == "current-access")
    #expect(store.accountLoginErrors[.claude]?.contains("status 9") == true)
  }

  @Test func failedLoginRestoresAFileOnlyClaudeAccountWithoutRecreatingTheKeychain() async throws {
    let context = try makeClaudeLoginContext(source: .credentialsFile)
    let interruptedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(observedManagedOperation: { provider, _, preserve, mutation, observation in
      try await preserve?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      mutation?()
      context.liveCredential.value = interruptedPayload
      observation?(context.loginObservation(keychainPayload: interruptedPayload))
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let restoredFile = try ClaudeCredentialsStore.parse(Data(contentsOf: context.credentialFileURL))
    #expect(context.liveCredential.value == nil)
    #expect(restoredFile.accessToken == "current-access")
    #expect(store.accountLoginErrors[.claude]?.contains("status 9") == true)
    #expect(store.accountLoginErrors[.claude]?.contains("also couldn’t restore") == false)
  }
}
