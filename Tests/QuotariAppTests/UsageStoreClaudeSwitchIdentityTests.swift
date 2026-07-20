import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeSwitchIdentityTests {
  @Test func organizationOnlyCacheDoesNotReplaceAnExactSavedIdentity() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let keychain = ClaudeSwitchKeychainBox()
    let (savedAccount, savedPayload) = try savedClaudeSwitchTarget(in: registry)
    let liveKeychain = ProviderAccount(
      provider: .claude,
      displayName: "Live",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )
    let liveFile = ProviderAccount(
      provider: .claude,
      displayName: "Live",
      detail: "Credentials file",
      credentialSource: .claudeCredentialsFile(path: "/tmp/.credentials.json")
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(accounts: [.claude: [savedAccount]]))
    let store = claudeSwitchIdentityStore(
      registry: registry,
      home: home,
      keychain: keychain,
      savedPayload: savedPayload,
      discovery: discovery
    )
    await store.reloadAccounts()
    store.claudeProfiles[savedAccount.id] = ClaudeProfile(
      organizationName: "Organization Only",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "s")
    )
    discovery.update(StaticAccountDiscovery(
      accounts: [.claude: [liveKeychain, liveFile]],
      liveEquivalents: [savedAccount.id: liveKeychain],
      capturedCopies: [liveKeychain.id: savedAccount, liveFile.id: savedAccount]
    ))

    await store.switchCLIAccount(to: savedAccount)

    #expect(store.captureErrors[.claude] == nil)
    #expect(store.selectedAccounts[.claude]?.credentialSource == .claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    ))
    let terminalIdentity = try #require(
      try ClaudeCodeAccountState.oauthAccount(from: Data(contentsOf: home.appendingPathComponent(".claude.json")))
    )
    #expect(ClaudeCodeAccountState.matches(
      terminalIdentity,
      profile: ClaudeProfile(accountID: "saved", email: "saved@example.com")
    ))
  }
}

private func savedClaudeSwitchTarget(
  in registry: CapturedAccountStore
) throws -> (ProviderAccount, Data) {
  let payload = Data(
    #"{"claudeAiOauth":{"accessToken":"s","refreshToken":"s-ref","expiresAt":9999999999999}}"#.utf8
  )
  try registry.save(CapturedAccount(
    id: "claude:fp-saved",
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Keychain",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: payload,
    claudeOAuthAccount: Data(#"{"accountUuid":"saved","emailAddress":"saved@example.com"}"#.utf8)
  ))
  return try (#require(registry.account(id: "claude:fp-saved")?.providerAccount), payload)
}

@MainActor
private func claudeSwitchIdentityStore(
  registry: CapturedAccountStore,
  home: URL,
  keychain: ClaudeSwitchKeychainBox,
  savedPayload: Data,
  discovery: MutableAccountDiscovery
) -> UsageStore {
  UsageStore.isolatedForTesting(
    providers: ProviderFixtures.descriptors.filter { $0.id == .claude },
    costEstimator: EmptyCostEstimator(),
    accountDiscovery: discovery,
    accountSwitch: .isolatedForTesting(
      capturedAccounts: registry,
      home: home,
      keychainRead: { _ in keychain.value },
      keychainWrite: { payload, _ in keychain.value = payload }
    ),
    claudeCredentialLoader: { source in
      guard case .quotariRegistry(id: "claude:fp-saved") = source else { return nil }
      return try? ClaudeCredentialsStore.parse(savedPayload)
    },
    startsAutomatically: false
  )
}

private final class ClaudeSwitchKeychainBox: @unchecked Sendable {
  private let lock = NSLock()
  private var payload: Data?

  var value: Data? {
    get { lock.withLock { payload } }
    set { lock.withLock { payload = newValue } }
  }
}
