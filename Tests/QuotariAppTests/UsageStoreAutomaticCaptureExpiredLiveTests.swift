import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct AutomaticCaptureExpiredLiveTests {
  @Test func expiredLiveClaudeRotationRemainsManagedWhenUsageFails() async throws {
    let fixture = try await makeExpiredLiveFixture()

    await fixture.store.reloadAccounts()

    let managed = fixture.registry.load().filter { $0.id != "claude:other" }
    let live = try #require(fixture.store.accounts[.claude]?.first {
      !$0.credentialSource.isCaptured
    })
    #expect(managed.count == 1)
    #expect(fixture.store.selectedAccounts[.claude] == live)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.id == managed.first?.providerAccount.id)
    #expect(fixture.selectionStore.load()[.claude]?.id == managed.first?.providerAccount.id)
    #expect(fixture.store.captureErrors[.claude] == nil)
  }
}

private struct ExpiredLiveFixture {
  let registry: CapturedAccountStore
  let selectionStore: ProviderAccountSelectionStore
  let store: UsageStore
}

@MainActor
private func makeExpiredLiveFixture() async throws -> ExpiredLiveFixture {
  let directory = try TemporaryDirectory()
  let expiredPayload = claudePayload(
    accessToken: "expired-live-access",
    refreshToken: "expired-live-refresh",
    expiresAt: Date(timeIntervalSince1970: 0)
  )
  let refreshedPayload = claudePayload(
    accessToken: "refreshed-live-access",
    refreshToken: "refreshed-live-refresh",
    expiresAt: Date().addingTimeInterval(3600)
  )
  let payload = AutomaticCapturePayloadBox(expiredPayload)
  let registry = try expiredLiveRegistry()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { payload.value },
    capturedAccounts: registry
  )
  let selected = try #require(await discovery.accounts(for: .claude).first {
    !$0.credentialSource.isCaptured
  })
  let selectionStore = ProviderAccountSelectionStore(
    url: directory.url.appendingPathComponent("selection.json")
  )
  try selectionStore.save([.claude: selected])
  let strategy = FailingCredentialRotationStrategy(
    payload: payload,
    rotatedPayload: refreshedPayload
  )
  let store = UsageStore.isolatedForTesting(
    providers: [expiredLiveDescriptor(strategy)],
    accountDiscovery: discovery,
    accountSelectionStore: selectionStore,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: expiredLiveProfiles),
    claudeCredentialLoader: expiredLiveLoader(payload: payload, registry: registry),
    startsAutomatically: false
  )
  return ExpiredLiveFixture(
    registry: registry,
    selectionStore: selectionStore,
    store: store
  )
}

private let expiredLiveProfiles = [
  "other-access": ClaudeProfile(accountID: "other", email: "other@example.com"),
  "refreshed-live-access": ClaudeProfile(accountID: "selected", email: "selected@example.com"),
]

private func expiredLiveRegistry() throws -> CapturedAccountStore {
  let registry = CapturedAccountStore.inMemoryForTesting()
  try registry.save(CapturedAccount(
    id: "claude:other",
    provider: .claude,
    displayName: "Other Claude",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: claudePayload(accessToken: "other-access", refreshToken: "other-refresh")
  ))
  return registry
}

private func expiredLiveDescriptor(
  _ strategy: FailingCredentialRotationStrategy
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

private func expiredLiveLoader(
  payload: AutomaticCapturePayloadBox,
  registry: CapturedAccountStore
) -> @Sendable (ProviderCredentialSource) -> ClaudeCredentials? {
  { source in
    switch source {
    case .claudeKeychain:
      try? ClaudeCredentialsStore.parse(payload.value)
    case let .quotariRegistry(id):
      registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
    case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
      nil
    }
  }
}

private actor FailingCredentialRotationStrategy: ProviderFetchStrategy {
  nonisolated let id = "failing-credential-rotation"
  nonisolated let kind = ProviderFetchKind.oauth
  private let payload: AutomaticCapturePayloadBox
  private let rotatedPayload: Data

  init(payload: AutomaticCapturePayloadBox, rotatedPayload: Data) {
    self.payload = payload
    self.rotatedPayload = rotatedPayload
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let sourceScopeID = try #require(context.account?.credentialScopeID)
    let credentials = try ClaudeCredentialsStore.parse(rotatedPayload)
    payload.value = rotatedPayload
    let target = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: nil,
      credentialSource: context.account?.credentialSource ?? .claudeKeychain(
        service: ClaudeCredentialsStore.keychainService
      ),
      credentialIdentity: credentials.accessToken
    )
    throw ProviderFetchTransitionError(
      underlying: SimulatedUsageFailure(),
      credentialTransitionTargetScopeID: target.credentialScopeID,
      credentialTransitionSourceScopeIDs: [sourceScopeID]
    )
  }
}

private struct SimulatedUsageFailure: LocalizedError {
  var errorDescription: String? {
    "The usage request failed after token refresh."
  }
}
