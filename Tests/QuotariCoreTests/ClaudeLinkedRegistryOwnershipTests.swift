import Foundation
@testable import QuotariCore
import Testing

struct ClaudeLinkedRegistryOwnershipTests {
  // swiftlint:disable:next function_body_length
  @Test func aDifferentSavedPendingGrantKeepsOwnershipWhenTheLiveWriteReturns() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    )
    let source = ProviderCredentialSource.claudeKeychain(service: "Test-Live-Claude")
    let live = KeychainSlot(
      claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    )
    let competingPending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(
        accessToken: "token-x",
        refreshToken: "ref-x",
        expiresAt: Date(timeIntervalSince1970: 100_000)
      ),
      previousAccessToken: "token-a",
      consumedRefreshToken: "ref-a"
    )
    let persister = PendingInjectingClaudePersister(
      inner: ClaudeCredentialsWriter(
        keychainRead: { _ in live.value },
        keychainWrite: { data, _ in live.value = data },
        capturedAccounts: store
      ),
      store: store,
      pending: competingPending,
      registryID: "claude:fp-1"
    )
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "token-b",
      refreshToken: "ref-b",
      expiresAt: Date(timeIntervalSince1970: 100_000)
    )))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: {
        guard let payload = live.value else {
          throw ClaudeCredentialPersistError.sourceUnavailable
        }
        return try ResolvedClaudeCredentials(
          credentials: ClaudeCredentialsStore.parse(payload),
          source: source
        )
      },
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      capturedRegistryID: "claude:fp-1"
    ))

    #expect(refresher.calls == ["ref-a"])
    let liveCredentials = try ClaudeCredentialsStore.parse(#require(live.value))
    #expect(liveCredentials.accessToken == "token-b")
    let saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"), capturedAccounts: store
    )
    #expect(saved.accessToken == "token-a")
    let pendingData = try #require(store.pendingGrantData(id: "claude:fp-1"))
    let pending = try JSONDecoder().decode(ClaudePendingGrant.self, from: pendingData)
    #expect(pending == competingPending)
  }
}

private final class PendingInjectingClaudePersister: ClaudeCredentialPersisting, @unchecked Sendable {
  private let inner: ClaudeCredentialsWriter
  private let store: CapturedAccountStore
  private let pending: ClaudePendingGrant
  private let registryID: String

  init(
    inner: ClaudeCredentialsWriter,
    store: CapturedAccountStore,
    pending: ClaudePendingGrant,
    registryID: String
  ) {
    self.inner = inner
    self.store = store
    self.pending = pending
    self.registryID = registryID
  }

  func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws {
    try inner.persist(grant, replacing: previousAccessToken, to: source)
    try store.savePendingGrant(JSONEncoder().encode(pending), id: registryID)
  }
}
