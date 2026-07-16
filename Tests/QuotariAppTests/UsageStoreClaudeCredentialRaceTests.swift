import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeCredentialRaceTests {
  @Test func lastMinuteRotationRefreshesTheExistingSavedAccount() async throws {
    let context = try makeClaudeLoginContext()
    let rotatedPayload = claudePayload(
      accessToken: "rotated-current-access",
      refreshToken: "rotated-current-refresh"
    )
    let rejectedPayload = claudePayload(
      accessToken: "interrupted-access",
      refreshToken: "interrupted-refresh"
    )
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      context.liveCredential.value = rotatedPayload
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        rotatedPayload
      )
      credentialMutation?()
      context.liveCredential.value = rejectedPayload
      throw AccountLoginError.commandFailed(provider, status: 9)
    })
    let store = context.makeStore(login: login, accountSwitch: context.makeSwitcher())

    await store.addAccount(for: .claude)

    let savedCredentials = try context.registry.load().map { captured in
      try ClaudeCredentialsStore.parse(captured.payload)
    }
    let liveCredential = try ClaudeCredentialsStore.parse(#require(context.liveCredential.value))
    #expect(savedCredentials.count == 2)
    #expect(savedCredentials.contains(where: { $0.accessToken == "current-access" }))
    #expect(savedCredentials.contains(where: { $0.accessToken == "interrupted-access" }))
    #expect(liveCredential.accessToken == "rotated-current-access")
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
    let login = AccountLoginService(managedOperation: { provider, _, preserveCredential, credentialMutation in
      context.liveCredential.value = interveningPayload
      try await preserveCredential?(
        provider,
        .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
        interveningPayload
      )
      credentialMutation?()
      context.liveCredential.value = interruptedPayload
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
