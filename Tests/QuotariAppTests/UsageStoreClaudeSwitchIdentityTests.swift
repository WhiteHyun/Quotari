import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeSwitchIdentityTests {
  @Test func organizationOnlyCacheDoesNotReplaceAnExactSavedIdentity() async throws {
    let fixture = try ClaudeSwitchIdentityFixture()
    await fixture.store.reloadAccounts()
    fixture.store.claudeProfiles[fixture.savedAccount.id] = ClaudeProfile(
      organizationName: "Organization Only",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "s")
    )
    fixture.publishLiveAccounts()

    await fixture.store.switchCLIAccount(to: fixture.savedAccount)
    await fixture.delay.waitUntilRequested()

    #expect(await fixture.strategy.requestCount == 0)
    await fixture.delay.resumeAll()
    await fixture.store.delayedCredentialRefreshTasks[.claude]?.task.value
    await fixture.store.selectionRefreshTasks[.claude]?.value

    #expect(fixture.store.captureErrors[.claude] == nil)
    #expect(await fixture.strategy.requestCount == 1)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == .claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    ))
    let terminalIdentity = try #require(
      try ClaudeCodeAccountState.oauthAccount(
        from: Data(contentsOf: fixture.home.appendingPathComponent(".claude.json"))
      )
    )
    #expect(ClaudeCodeAccountState.matches(
      terminalIdentity,
      profile: ClaudeProfile(accountID: "saved", email: "saved@example.com")
    ))
  }
}

@MainActor
private final class ClaudeSwitchIdentityFixture {
  let directory: TemporaryDirectory
  let home: URL
  let registry: CapturedAccountStore
  let keychain = ClaudeSwitchKeychainBox()
  let strategy = AutomaticCaptureCountingStrategy()
  let delay = PostCredentialRefreshGate()
  let savedAccount: ProviderAccount
  let savedPayload: Data
  let liveKeychain: ProviderAccount
  let liveFile: ProviderAccount
  let discovery: MutableAccountDiscovery
  lazy var store = claudeSwitchIdentityStore(
    context: ClaudeSwitchIdentityStoreContext(
      registry: registry,
      home: home,
      keychain: keychain,
      savedPayload: savedPayload,
      discovery: discovery
    ),
    descriptor: countingClaudeDescriptor(strategy: strategy),
    postCredentialRefreshSleep: delay.sleep
  )

  init() throws {
    directory = try TemporaryDirectory()
    home = directory.url
    registry = CapturedAccountStore.inMemoryForTesting()
    (savedAccount, savedPayload) = try savedClaudeSwitchTarget(in: registry)
    liveKeychain = ProviderAccount(
      provider: .claude,
      displayName: "Live",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
    )
    liveFile = ProviderAccount(
      provider: .claude,
      displayName: "Live",
      detail: "Credentials file",
      credentialSource: .claudeCredentialsFile(path: "/tmp/.credentials.json")
    )
    discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.claude: [savedAccount]]
    ))
  }

  func publishLiveAccounts() {
    discovery.update(StaticAccountDiscovery(
      accounts: [.claude: [liveKeychain, liveFile]],
      liveEquivalents: [savedAccount.id: liveKeychain],
      capturedCopies: [liveKeychain.id: savedAccount, liveFile.id: savedAccount]
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
  context: ClaudeSwitchIdentityStoreContext,
  descriptor: ProviderDescriptor,
  postCredentialRefreshSleep: @escaping @Sendable (Duration) async throws -> Void
) -> UsageStore {
  UsageStore.isolatedForTesting(
    providers: [descriptor],
    costEstimator: EmptyCostEstimator(),
    accountDiscovery: context.discovery,
    accountSwitch: .isolatedForTesting(
      capturedAccounts: context.registry,
      home: context.home,
      keychainRead: { _ in context.keychain.value },
      keychainWrite: { payload, _ in context.keychain.value = payload }
    ),
    claudeCredentialLoader: { source in
      guard case .quotariRegistry(id: "claude:fp-saved") = source else { return nil }
      return try? ClaudeCredentialsStore.parse(context.savedPayload)
    },
    postCredentialRefreshSleep: postCredentialRefreshSleep,
    startsAutomatically: false
  )
}

private struct ClaudeSwitchIdentityStoreContext {
  let registry: CapturedAccountStore
  let home: URL
  let keychain: ClaudeSwitchKeychainBox
  let savedPayload: Data
  let discovery: MutableAccountDiscovery
}

private final class ClaudeSwitchKeychainBox: @unchecked Sendable {
  private let lock = NSLock()
  private var payload: Data?

  var value: Data? {
    get { lock.withLock { payload } }
    set { lock.withLock { payload = newValue } }
  }
}
