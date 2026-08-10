import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureFreshnessTests {
  @Test func olderLiveClaudeGenerationCannotReplaceNewerSavedCredentials() async throws {
    let fixture = try makeClaudeFreshnessFixture()

    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.account(id: "claude:saved"))
    let savedCredentials = try ClaudeCredentialsStore.parse(saved.payload)
    let live = try #require(fixture.store.accounts[.claude]?.first(where: { !$0.credentialSource.isCaptured }))
    #expect(savedCredentials.accessToken == "newer-saved-access")
    #expect(savedCredentials.refreshToken == "newer-saved-refresh")
    #expect(fixture.store.capturedEquivalents[live.id]?.credentialSource == .quotariRegistry(id: saved.id))

    let savedAccount = try #require(fixture.store.accounts[.claude]?.first(where: { $0.credentialSource.isCaptured }))
    await fixture.store.removeCapturedAccount(savedAccount)

    #expect(fixture.registry.account(id: saved.id) != nil)
    #expect(fixture.store.captureErrors[.claude] == UsageStore.activeAccountRemovalMessage)
  }

  @Test func scanAnchorsSelectionAfterAnInFlightClaudeRotation() async throws {
    let fixture = try await makeClaudeRotationFixture()
    fixture.store.beginRefresh()
    await fixture.strategy.waitUntilRequestStarts()
    let reload = Task { await fixture.store.reloadAccounts() }
    #expect(await waitUntilAutomaticCaptureStarts(fixture.store, provider: .claude))

    await fixture.strategy.resumeWithRotatedPayload()
    await reload.value
    await fixture.store.inFlightRefresh?.value

    #expect(fixture.store.captureErrors[.claude] == nil)
    let saved = try #require(fixture.registry.load().first)
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    let live = try #require(fixture.store.accounts[.claude]?.first(where: { !$0.credentialSource.isCaptured }))
    #expect(credentials.accessToken == "access-b")
    #expect(credentials.refreshToken == "refresh-b")
    #expect(fixture.store.selectedAccounts[.claude] == live)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
  }

  @Test func scanAnchorsSelectionAfterAJustCompletedClaudeRotation() async throws {
    let fixture = try await makeClaudeRotationFixture()
    fixture.store.beginRefresh()
    await fixture.strategy.waitUntilRequestStarts()
    await fixture.strategy.resumeWithRotatedPayload()
    await fixture.store.inFlightRefresh?.value
    #expect(fixture.store.providerFetchTasks[.claude] == nil)

    await fixture.store.reloadAccounts()

    #expect(fixture.store.captureErrors[.claude] == nil)
    let saved = try #require(fixture.registry.load().first)
    let live = try #require(fixture.store.accounts[.claude]?.first(where: { !$0.credentialSource.isCaptured }))
    #expect(fixture.store.selectedAccounts[.claude] == live)
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
  }
}

private struct ClaudeFreshnessFixture {
  let registry: CapturedAccountStore
  let store: UsageStore
}

@MainActor
private func makeClaudeFreshnessFixture() throws -> ClaudeFreshnessFixture {
  let directory = try TemporaryDirectory()
  let livePayload = claudePayload(
    accessToken: "older-live-access",
    refreshToken: "older-live-refresh",
    expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
  )
  let savedPayload = claudePayload(
    accessToken: "newer-saved-access",
    refreshToken: "newer-saved-refresh",
    expiresAt: Date(timeIntervalSince1970: 2_000_003_600)
  )
  let registry = CapturedAccountStore.inMemoryForTesting()
  try registry.save(freshnessCapturedAccount(payload: savedPayload))
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
      accountID: "stable-claude-account",
      email: "claude@example.com"
    ),
    claudeCredentialLoader: { freshnessCredentials(source: $0, livePayload: livePayload, registry: registry) },
    startsAutomatically: false
  )
  return ClaudeFreshnessFixture(registry: registry, store: store)
}

private func freshnessCapturedAccount(payload: Data) -> CapturedAccount {
  CapturedAccount(
    id: "claude:saved",
    provider: .claude,
    displayName: "Claude account",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 1),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: payload
  )
}

private func freshnessCredentials(
  source: ProviderCredentialSource,
  livePayload: Data,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  switch source {
  case .claudeKeychain:
    try? ClaudeCredentialsStore.parse(livePayload)
  case let .quotariRegistry(id):
    registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
  case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
    nil
  }
}

private struct ClaudeRotationFixture {
  let registry: CapturedAccountStore
  let selectionStore: ProviderAccountSelectionStore
  let strategy: GatedCredentialRotationStrategy
  let store: UsageStore
}

@MainActor
private func makeClaudeRotationFixture() async throws -> ClaudeRotationFixture {
  let directory = try TemporaryDirectory()
  let initial = claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
  let rotated = claudePayload(accessToken: "access-b", refreshToken: "refresh-b")
  let payload = AutomaticCapturePayloadBox(initial)
  let registry = CapturedAccountStore.inMemoryForTesting()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { payload.value },
    capturedAccounts: registry
  )
  let selected = try #require(await discovery.accounts(for: .claude).first)
  let selectionStore = ProviderAccountSelectionStore(url: directory.url.appendingPathComponent("selection.json"))
  try selectionStore.save([.claude: selected])
  let strategy = GatedCredentialRotationStrategy(payload: payload, rotatedPayload: rotated)
  let descriptor = ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(displayName: "Claude", accent: .init(0.8, 0.5, 0.2), supportsWeekly: true),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
  let store = UsageStore.isolatedForTesting(
    providers: [descriptor],
    accountDiscovery: discovery,
    accountSelectionStore: selectionStore,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "rotation-account",
      email: "rotation@example.com"
    ),
    claudeCredentialLoader: {
      automaticCaptureClaudeCredentials(
        source: $0,
        keychainPayload: payload.value,
        registry: registry
      )
    },
    startsAutomatically: false
  )
  return ClaudeRotationFixture(
    registry: registry,
    selectionStore: selectionStore,
    strategy: strategy,
    store: store
  )
}

@MainActor
private func waitUntilAutomaticCaptureStarts(
  _ store: UsageStore,
  provider: UsageProvider
) async -> Bool {
  for _ in 0 ..< 100 {
    if store.automaticallyCapturingProviders.contains(provider) {
      return true
    }
    await Task.yield()
  }
  return store.automaticallyCapturingProviders.contains(provider)
}
