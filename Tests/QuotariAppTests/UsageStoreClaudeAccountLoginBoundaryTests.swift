import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ClaudeLoginBoundaryTests {
  @Test func accountStateChangeDuringPreservationAbortsBeforeLoginMutation() async throws {
    let context = try makeClaudeLoginContext()
    let accountStateURL = context.directory.url.appendingPathComponent(".claude.json")
    let initialState = Data(
      #"{"oauthAccount":{"accountUuid":"account-current","emailAddress":"current@example.com"}}"#.utf8
    )
    let concurrentState = Data(
      #"{"oauthAccount":{"accountUuid":"external","emailAddress":"external@example.com"}}"#.utf8
    )
    try initialState.write(to: accountStateURL)
    let profiles = AccountLoginGatedClaudeProfileFetcher(
      gatedAccessToken: "current-access",
      gatedRequest: nil,
      profiles: [
        "current-access": ClaudeProfile(
          accountID: "account-current",
          email: "current@example.com",
          organizationID: "organization-current"
        ),
      ]
    )
    let mutationStarted = ClaudeLoginBooleanBox()
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      await profiles.armNextRequest()
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      mutationStarted.value = true
      credentialMutation?()
      return try AccountLoginResult(
        provider: provider,
        origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        payload: #require(context.liveCredential.value)
      )
    })
    let store = context.makeStore(login: login, profileFetcher: profiles)
    let loginTask = Task { await store.addAccount(for: .claude) }
    await profiles.waitUntilRequestStarts()

    try concurrentState.write(to: accountStateURL)
    await profiles.resume()
    await loginTask.value

    #expect(!mutationStarted.value)
    #expect(try Data(contentsOf: accountStateURL) == concurrentState)
    #expect(store.accountLoginErrors[.claude]?.contains("kept changing") == true)
  }

  @Test func missingPostLoginObservationLeavesTheCurrentGenerationUntouched() async throws {
    let context = try makeClaudeLoginContext()
    let accountStateURL = context.directory.url.appendingPathComponent(".claude.json")
    let previousState = Data(
      #"{"oauthAccount":{"accountUuid":"account-current","emailAddress":"current@example.com"}}"#.utf8
    )
    let unobservedState = Data(
      #"{"oauthAccount":{"accountUuid":"external","emailAddress":"external@example.com"}}"#.utf8
    )
    try previousState.write(to: accountStateURL)
    let unobservedPayload = claudePayload(
      accessToken: "unobserved-access",
      refreshToken: "unobserved-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        context.liveCredential.value
      )
      credentialMutation?()
      context.liveCredential.value = unobservedPayload
      try unobservedState.write(to: accountStateURL)
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    #expect(context.liveCredential.value == unobservedPayload)
    #expect(try Data(contentsOf: accountStateURL) == unobservedState)
    #expect(store.accountLoginErrors[.claude]?.contains("recovery error") == true)
    #expect(store.accountLoginErrors[.claude]?.contains("left the current CLI login untouched") == true)
  }
}
