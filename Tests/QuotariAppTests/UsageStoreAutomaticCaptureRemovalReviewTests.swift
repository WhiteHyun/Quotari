import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct AutomaticCaptureRemovalReviewTests {
  @Test func organizationOnlyProfilesKeepRemovalFailClosed() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedPayload = claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    let livePayload = claudePayload(accessToken: "live-access", refreshToken: "live-refresh")
    try registry.save(CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 1),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: savedPayload
    ))
    let saved = try #require(registry.account(id: "claude:saved")?.providerAccount)
    let live = ProviderAccount(
      provider: .claude,
      displayName: "Live Claude",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      credentialIdentity: "live-access"
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [live, saved]]),
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      claudeCredentialLoader: { source in
        let payload: Data? = switch source {
        case .claudeKeychain:
          livePayload
        case .quotariRegistry:
          savedPayload
        case .claudeCredentialsFile, .claudeEnvironment, .codexAuthFile, .codexKeychain:
          nil
        }
        return payload.flatMap { try? ClaudeCredentialsStore.parse($0) }
      },
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.claudeProfiles[saved.id] = ClaudeProfile(
      organizationName: "Saved Organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "saved-access")
    )
    store.claudeProfiles[live.id] = ClaudeProfile(
      organizationName: "Live Organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "live-access")
    )

    await store.removeCapturedAccount(saved)

    #expect(registry.account(id: "claude:saved") != nil)
    #expect(store.captureErrors[.claude] == UsageStore.activeAccountRemovalMessage)
  }

  @Test func legacyProfilesWithoutCredentialProofBlockSavedCopyRemoval() async throws {
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 1),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    ))
    let saved = try #require(registry.account(id: "claude:saved")?.providerAccount)
    let live = ProviderAccount(
      provider: .claude,
      displayName: "Live Claude",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      credentialIdentity: "live-access"
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [live, saved]]),
      accountCapture: AccountCaptureService(capturedAccounts: registry),
      claudeCredentialLoader: { _ in nil },
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.claudeProfiles[saved.id] = ClaudeProfile(accountID: "saved-account")
    store.claudeProfiles[live.id] = ClaudeProfile(accountID: "live-account")

    await store.removeCapturedAccount(saved)

    #expect(registry.account(id: "claude:saved") != nil)
    #expect(store.captureErrors[.claude] == UsageStore.activeAccountRemovalMessage)
  }
}
