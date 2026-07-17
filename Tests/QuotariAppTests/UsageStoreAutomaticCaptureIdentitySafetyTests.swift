import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct AutomaticCaptureIdentitySafetyTests {
  @Test func externalClaudeReloginDuringFetchDoesNotInheritThePreviousSelection() async throws {
    let directory = try TemporaryDirectory()
    let payload = AutomaticCapturePayloadBox(
      claudePayload(accessToken: "account-a-access", refreshToken: "account-a-refresh")
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let selected = try #require(await discovery.accounts(for: .claude).first)
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("selection.json")
    )
    try selectionStore.save([.claude: selected])
    let strategy = GatedNonRotatingClaudeStrategy()
    let store = UsageStore.isolatedForTesting(
      providers: [identitySafetyClaudeDescriptor(strategy: strategy)],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in payload.value }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    store.beginRefresh()
    await strategy.waitUntilRequestStarts()
    let reload = Task { await store.reloadAccounts() }
    #expect(await waitUntilIdentitySafetyCaptureStarts(store))
    payload.value = claudePayload(
      accessToken: "account-b-access",
      refreshToken: "account-b-refresh"
    )
    await strategy.resume()
    await reload.value
    await store.inFlightRefresh?.value

    #expect(registry.load().count == 1)
    #expect(store.selectedAccounts[.claude] == nil)
    #expect(selectionStore.load()[.claude] == nil)
  }

  @Test func unreadableSavedClaudeCredentialBlocksDuplicateCapture() async throws {
    let directory = try TemporaryDirectory()
    let livePayload = claudePayload(
      accessToken: "rotated-live-access",
      refreshToken: "rotated-live-refresh"
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    ))
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { livePayload },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in livePayload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: StableClaudeProfileFetcher(
        accountID: "stable-account",
        email: "same@example.com"
      ),
      claudeCredentialLoader: { source in
        guard !source.isCaptured else { return nil }
        return try? ClaudeCredentialsStore.parse(livePayload)
      },
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(registry.load().map(\.id) == ["claude:saved"])
    #expect(store.captureErrors[.claude]?.contains("every saved Claude account") == true)
  }

  @Test func organizationOnlyProfileDoesNotCreateAnotherManagedAccount() async throws {
    let directory = try TemporaryDirectory()
    let livePayload = claudePayload(
      accessToken: "organization-only-access",
      refreshToken: "organization-only-refresh"
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    ))
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { livePayload },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in livePayload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "organization-only-access": ClaudeProfile(organizationName: "Example Organization"),
        "saved-access": ClaudeProfile(accountID: "saved-account", email: "saved@example.com"),
      ]),
      claudeCredentialLoader: { source in
        identitySafetyCredentials(source: source, livePayload: livePayload, registry: registry)
      },
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(registry.load().map(\.id) == ["claude:saved"])
    #expect(store.captureErrors[.claude]?.contains("verify this Claude account") == true)
  }

  @Test func cachedOrganizationOnlyProfileDoesNotCreateAnotherManagedAccount() async throws {
    let directory = try TemporaryDirectory()
    let livePayload = claudePayload(
      accessToken: "organization-only-access",
      refreshToken: "organization-only-refresh"
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    ))
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { livePayload },
      capturedAccounts: registry
    )
    let liveAccount = try #require(await discovery.accounts(for: .claude).first(where: {
      !$0.credentialSource.isCaptured
    }))
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in livePayload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "organization-only-access": ClaudeProfile(organizationName: "Example Organization"),
        "saved-access": ClaudeProfile(accountID: "saved-account", email: "saved@example.com"),
      ]),
      claudeCredentialLoader: { source in
        identitySafetyCredentials(source: source, livePayload: livePayload, registry: registry)
      },
      startsAutomatically: false
    )
    store.claudeProfiles[liveAccount.id] = ClaudeProfile(
      organizationName: "Cached Organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "organization-only-access")
    )

    await store.reloadAccounts()

    #expect(registry.load().map(\.id) == ["claude:saved"])
    #expect(store.captureErrors[.claude]?.contains("verify this Claude account") == true)
  }
}

private actor GatedNonRotatingClaudeStrategy: ProviderFetchStrategy {
  nonisolated let id = "gated-non-rotating-claude"
  nonisolated let kind = ProviderFetchKind.oauth
  private var continuation: CheckedContinuation<Void, Never>?
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    started = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
    await withCheckedContinuation { continuation = $0 }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Unchanged",
      credentialScopeID: context.account?.credentialScopeID
    )
  }

  func waitUntilRequestStarts() async {
    guard !started else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

private func identitySafetyClaudeDescriptor(
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

private func identitySafetyCredentials(
  source: ProviderCredentialSource,
  livePayload: Data,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  let payload: Data? = switch source {
  case .claudeKeychain:
    livePayload
  case let .quotariRegistry(id):
    registry.account(id: id)?.payload
  case .claudeCredentialsFile, .claudeEnvironment, .codexAuthFile, .codexKeychain:
    nil
  }
  return payload.flatMap { try? ClaudeCredentialsStore.parse($0) }
}

@MainActor
private func waitUntilIdentitySafetyCaptureStarts(_ store: UsageStore) async -> Bool {
  for _ in 0 ..< 100 {
    if store.automaticallyCapturingProviders.contains(.claude) {
      return true
    }
    await Task.yield()
  }
  return store.automaticallyCapturingProviders.contains(.claude)
}
