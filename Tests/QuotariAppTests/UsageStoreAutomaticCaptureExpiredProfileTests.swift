import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct ExpiredClaudeCaptureProfileTests {
  @Test func expiredSavedClaudeAccountRefreshesBeforeResolvingItsProfile() async throws {
    let fixture = try makeExpiredSavedClaudeFixture()

    await fixture.store.reloadAccounts()

    #expect(await fixture.strategy.requestCount == 1)
    #expect(fixture.registry.load().count == 2)
    let refreshed = try #require(fixture.registry.account(id: "claude:expired"))
    #expect(try ClaudeCredentialsStore.parse(refreshed.payload).accessToken == "saved-fresh-access")
    #expect(fixture.store.captureErrors[.claude] == nil)
  }

  @Test func pinnedProfileLinksARotatedLiveLoginWhenSavedRefreshFails() async throws {
    let fixture = try makePinnedExpiredSavedClaudeFixture()

    await fixture.store.reloadAccounts()

    #expect(fixture.registry.load().map(\.id) == ["claude:expired"])
    let refreshed = try #require(fixture.registry.account(id: "claude:expired"))
    #expect(try ClaudeCredentialsStore.parse(refreshed.payload).accessToken == "rotated-live-access")
    #expect(fixture.store.captureErrors[.claude] == nil)
  }
}

private struct PinnedExpiredSavedClaudeFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let store: UsageStore
}

@MainActor
private func makePinnedExpiredSavedClaudeFixture() throws -> PinnedExpiredSavedClaudeFixture {
  let directory = try TemporaryDirectory()
  let registry = try expiredClaudeRegistry()
  let livePayload = try expiringClaudePayload(
    accessToken: "rotated-live-access",
    refreshToken: "rotated-live-refresh",
    expiresAt: Date().addingTimeInterval(3600)
  )
  let profileStore = ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json"))
  let savedAccountID = ProviderAccount.id(
    provider: .claude,
    source: .quotariRegistry(id: "claude:expired")
  )
  let profile = ClaudeProfile(accountID: "same-account", email: "same@example.com")
  try profileStore.save([
    savedAccountID: profile.verified(
      for: ProviderCredentialIdentity.fingerprint(of: "saved-expired-access")
    ),
  ])
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { livePayload },
    capturedAccounts: registry
  )
  let store = UsageStore.isolatedForTesting(
    providers: [unrefreshableSavedClaudeDescriptor()],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in livePayload }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "rotated-live-access": profile,
    ]),
    profileStore: profileStore,
    claudeCredentialLoader: { source in
      switch source {
      case .claudeKeychain:
        try? ClaudeCredentialsStore.parse(livePayload)
      case let .quotariRegistry(id):
        registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
      case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
        nil
      }
    },
    startsAutomatically: false
  )
  return PinnedExpiredSavedClaudeFixture(directory: directory, registry: registry, store: store)
}

private func unrefreshableSavedClaudeDescriptor() -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.4, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [UnrefreshableSavedClaudeStrategy()] }
  )
}

private struct UnrefreshableSavedClaudeStrategy: ProviderFetchStrategy {
  let id = "unrefreshable-saved-claude"
  let kind = ProviderFetchKind.oauth

  func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
    throw UnrefreshableSavedClaudeError()
  }
}

private struct UnrefreshableSavedClaudeError: LocalizedError {
  var errorDescription: String? {
    "The saved credential could not refresh."
  }
}

private struct ExpiredSavedClaudeFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let strategy: SavedClaudeCredentialRefreshStrategy
  let store: UsageStore
}

@MainActor
private func makeExpiredSavedClaudeFixture() throws -> ExpiredSavedClaudeFixture {
  let directory = try TemporaryDirectory()
  let registry = try expiredClaudeRegistry()
  let freshPayload = try expiringClaudePayload(
    accessToken: "saved-fresh-access",
    refreshToken: "saved-fresh-refresh",
    expiresAt: Date().addingTimeInterval(3600)
  )
  let strategy = SavedClaudeCredentialRefreshStrategy(registry: registry, freshPayload: freshPayload)
  let livePayload = claudePayload(accessToken: "live-access", refreshToken: "live-refresh")
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { livePayload },
    capturedAccounts: registry
  )
  let store = UsageStore.isolatedForTesting(
    providers: [expiredSavedClaudeDescriptor(strategy: strategy)],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in livePayload }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "saved-fresh-access": ClaudeProfile(accountID: "saved-account", email: "saved@example.com"),
      "live-access": ClaudeProfile(accountID: "live-account", email: "live@example.com"),
    ]),
    claudeCredentialLoader: { source in
      switch source {
      case .claudeKeychain:
        try? ClaudeCredentialsStore.parse(livePayload)
      case let .quotariRegistry(id):
        registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
      case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
        nil
      }
    },
    startsAutomatically: false
  )
  return ExpiredSavedClaudeFixture(
    directory: directory,
    registry: registry,
    strategy: strategy,
    store: store
  )
}

private actor SavedClaudeCredentialRefreshStrategy: ProviderFetchStrategy {
  nonisolated let id = "saved-claude-credential-refresh"
  nonisolated let kind = ProviderFetchKind.oauth
  private let registry: CapturedAccountStore
  private let freshPayload: Data
  private(set) var requestCount = 0

  init(registry: CapturedAccountStore, freshPayload: Data) {
    self.registry = registry
    self.freshPayload = freshPayload
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    guard case let .quotariRegistry(id) = context.account?.credentialSource else {
      throw CancellationError()
    }
    requestCount += 1
    try registry.updatePayload(id: id) { _ in freshPayload }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: .claude, updatedAt: context.now),
      sourceLabel: "Refreshed"
    )
  }
}

private func expiredSavedClaudeDescriptor(
  strategy: SavedClaudeCredentialRefreshStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.4, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

private func expiringClaudePayload(
  accessToken: String,
  refreshToken: String,
  expiresAt: Date
) throws -> Data {
  let oauth: [String: Any] = [
    "accessToken": accessToken,
    "refreshToken": refreshToken,
    "expiresAt": Int(expiresAt.timeIntervalSince1970 * 1000),
  ]
  return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
}

private func expiredClaudeRegistry() throws -> CapturedAccountStore {
  let registry = CapturedAccountStore.inMemoryForTesting()
  let payload = try expiringClaudePayload(
    accessToken: "saved-expired-access",
    refreshToken: "saved-refresh",
    expiresAt: Date(timeIntervalSince1970: 0)
  )
  try registry.save(CapturedAccount(
    id: "claude:expired",
    provider: .claude,
    displayName: "Expired Claude",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: payload
  ))
  return registry
}
