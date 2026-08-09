import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreClaudeSwitchIdentityTests {
  @Test func resumeWarningKeepsTheCompletedSwitchAndRediscoveredSelection() async throws {
    let fixture = try ClaudeSwitchIdentityFixture(resumeFails: true)
    await fixture.store.reloadAccounts()
    fixture.store.claudeProfiles[fixture.savedAccount.id] = ClaudeProfile(
      accountID: "saved",
      email: "saved@example.com",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "s")
    )
    fixture.publishLiveAccounts()
    let snapshot = try await fixture.store.cliActivitySnapshot(for: .claude)

    await fixture.store.switchCLIAccount(
      to: fixture.savedAccount,
      allowingActiveSessions: snapshot
    )

    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == .claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    ))
    #expect(fixture.store.captureErrors[.claude] ==
      "The CLI account switched, but Quotari couldn't resume every paused Claude session: resume failed")
    await fixture.delay.resumeAll()
  }

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

  @Test func sameAccountUUIDInAnotherOrganizationBacksUpSeparately() async throws {
    let fixture = try ClaudeSwitchIdentityFixture()
    let livePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"live","refreshToken":"live-ref","expiresAt":9999999999999}}"#.utf8
    )
    fixture.keychain.value = livePayload
    fixture.publishLiveAccounts()
    await fixture.store.reloadAccounts()
    fixture.store.claudeProfiles[fixture.savedAccount.id] = ClaudeProfile(
      accountID: "shared-account",
      email: "shared@example.com",
      organizationID: "saved-organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "s")
    )
    fixture.store.claudeProfiles[fixture.liveKeychain.id] = ClaudeProfile(
      accountID: "shared-account",
      email: "shared@example.com",
      organizationID: "live-organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "live")
    )

    await fixture.store.switchCLIAccount(to: fixture.savedAccount)

    let captured = fixture.registry.load()
    let saved = try #require(captured.first(where: { $0.id == "claude:fp-saved" }))
    #expect(saved.payload == fixture.savedPayload)
    let backup = try #require(captured.first(where: { account in
      guard account.id != saved.id,
            let credentials = try? ClaudeCredentialsStore.parse(account.payload)
      else { return false }
      return credentials.accessToken == "live" && credentials.refreshToken == "live-ref"
    }))
    #expect(
      backup.claudeAccountIdentity == ClaudeAccountIdentity(
        accountID: "shared-account", email: "shared@example.com", organizationID: "live-organization"
      )
    )
    let installedCredentials = try ClaudeCredentialsStore.parse(#require(fixture.keychain.value))
    #expect(installedCredentials.accessToken == "s")
    #expect(installedCredentials.refreshToken == "s-ref")
    await fixture.delay.resumeAll()
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
  let resumeFails: Bool
  lazy var store = claudeSwitchIdentityStore(
    context: ClaudeSwitchIdentityStoreContext(
      registry: registry,
      home: home,
      keychain: keychain,
      savedPayload: savedPayload,
      discovery: discovery
    ),
    descriptor: countingClaudeDescriptor(strategy: strategy),
    postCredentialRefreshSleep: delay.sleep,
    resumeFails: resumeFails
  )

  init(resumeFails: Bool = false) throws {
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
    self.resumeFails = resumeFails
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
  postCredentialRefreshSleep: @escaping @Sendable (Duration) async throws -> Void,
  resumeFails: Bool
) -> UsageStore {
  let active = CLIActivityProcess(
    pid: 42,
    displayName: "claude (PID 42)",
    generation: .process(startTimeSeconds: 100, startTimeMicroseconds: 1)
  )
  return UsageStore.isolatedForTesting(
    providers: [descriptor],
    costEstimator: EmptyCostEstimator(),
    accountDiscovery: context.discovery,
    accountSwitch: .isolatedForTesting(
      capturedAccounts: context.registry,
      home: context.home,
      keychainRead: { _ in context.keychain.value },
      keychainWrite: { payload, _ in context.keychain.value = payload },
      activeCLIProcessRecords: { _ in resumeFails ? [active] : [] },
      processResumeLease: { _ in
        CLIProcessResumeLease(
          suspend: {},
          resume: {
            if resumeFails {
              throw NSError(
                domain: "CLIProcessResumeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "resume failed"]
              )
            }
          }
        )
      }
    ),
    claudeCredentialLoader: { source in
      let payload: Data? = switch source {
      case .claudeKeychain:
        context.keychain.value
      case let .quotariRegistry(id):
        context.registry.account(id: id)?.payload
      case .codexAuthFile, .codexKeychain, .claudeCredentialsFile, .claudeEnvironment:
        nil
      }
      return payload.flatMap { try? ClaudeCredentialsStore.parse($0) }
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
