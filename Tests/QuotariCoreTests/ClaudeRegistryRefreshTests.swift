import Foundation
@testable import QuotariCore
import Testing

let usageJSON = #"""
{"five_hour": { "utilization": 32, "resets_at": "2026-01-07T00:00:00+00:00" }}
"""#

func claudePayload(accessToken: String, refreshToken: String, expiresAt: TimeInterval) -> Data {
  Data(#"""
  {"claudeAiOauth": {"accessToken": "\#(accessToken)", "refreshToken": "\#(refreshToken)",
                     "expiresAt": \#(Int(expiresAt * 1000))}}
  """#.utf8)
}

func makeClaudeRegistryStore(payload: Data) throws -> CapturedAccountStore {
  let store = CapturedAccountStore(
    keychain: InMemoryKeychain().store,
    service: "Test-ClaudeReg-\(UUID().uuidString)"
  )
  try store.save(CapturedAccount(
    id: "claude:fp-1",
    provider: .claude,
    displayName: "Saved Claude",
    detail: nil,
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: "Claude Code-credentials"),
    payload: payload
  ))
  return store
}

func claudeRegistryAccount() -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Saved in Quotari",
    credentialSource: .quotariRegistry(id: "claude:fp-1")
  )
}

/// Delegates to the real writer after a scripted number of injected failures.
final class FlakyClaudePersister: ClaudeCredentialPersisting, @unchecked Sendable {
  struct InjectedFailure: Error {}

  private let inner: ClaudeCredentialsWriter
  private let lock = NSLock()
  private var failuresRemaining: Int

  init(inner: ClaudeCredentialsWriter, failures: Int) {
    self.inner = inner
    failuresRemaining = failures
  }

  func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws {
    let shouldFail: Bool = lock.withLock {
      guard failuresRemaining > 0 else { return false }
      failuresRemaining -= 1
      return true
    }
    if shouldFail {
      throw InjectedFailure()
    }
    try inner.persist(grant, replacing: previousAccessToken, to: source)
  }
}

/// Simulates a stale write whose follow-up reread also fails: the first
/// persist call blinds the registry item's reads and reports staleSource;
/// later calls delegate to the real writer.
final class BlindingClaudePersister: ClaudeCredentialPersisting, @unchecked Sendable {
  private let keychain: InMemoryKeychain
  private let blindService: String
  private let inner: ClaudeCredentialsWriter
  private let lock = NSLock()
  private var blinded = false

  init(store: CapturedAccountStore, keychain: InMemoryKeychain, blindService: String) {
    self.keychain = keychain
    self.blindService = blindService
    inner = ClaudeCredentialsWriter(capturedAccounts: store)
  }

  func persist(
    _ grant: ClaudeTokenGrant,
    replacing previousAccessToken: String,
    to source: ProviderCredentialSource
  ) throws {
    let shouldBlind: Bool = lock.withLock {
      guard !blinded else { return false }
      blinded = true
      return true
    }
    if shouldBlind {
      keychain.failReads(of: blindService)
      throw ClaudeCredentialPersistError.staleSource
    }
    try inner.persist(grant, replacing: previousAccessToken, to: source)
  }
}

/// Saved (registry) Claude accounts refresh like Codex ones: expired tokens
/// are exchanged and rotated pairs survive write-back failures — the registry
/// has no co-owner (unlike the CLI keychain/file) to heal a lost rotation.
struct ClaudeLinkedRegistryRefreshTests {
  // swiftlint:disable:next function_body_length
  @Test func aQueuedCachedBridgeBlocksTheNextLiveRotation() async throws {
    let keychain = InMemoryKeychain()
    let prefix = "Test-BlockedBridge-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: prefix)
    try store.save(CapturedAccount(
      id: "claude:fp-1",
      provider: .claude,
      displayName: "Saved Claude",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: "Test-Live-Claude"),
      payload: claudePayload(accessToken: "token-a", refreshToken: "ref-a", expiresAt: 1000)
    ))
    let source = ProviderCredentialSource.claudeKeychain(service: "Test-Live-Claude")
    let bridge = ClaudePendingGrant(
      grant: ClaudeTokenGrant(
        accessToken: "token-b",
        refreshToken: "ref-b",
        expiresAt: Date(timeIntervalSince1970: 1000)
      ),
      previousAccessToken: "token-a",
      consumedRefreshToken: "ref-a"
    )
    let coordinator = ClaudeTokenRefreshCoordinator()
    _ = await coordinator.resolve(key: "\(source.stableID)#ref-a") {
      ClaudeRefreshResolution(
        resolved: ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(
            accessToken: "token-b",
            refreshToken: "ref-b",
            expiresAt: Date(timeIntervalSince1970: 1000)
          ),
          source: source
        ),
        acceptedGrant: bridge
      )
    }
    keychain.failWrites(of: "\(prefix).claude:fp-1")
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "token-c",
      refreshToken: "ref-c"
    )))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(
            accessToken: "token-b",
            refreshToken: "ref-b",
            expiresAt: Date(timeIntervalSince1970: 1000)
          ),
          source: source
        )
      },
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      capturedRegistryID: "claude:fp-1"
    ))

    #expect(refresher.calls.isEmpty)
    let saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"), capturedAccounts: store
    )
    #expect(saved.accessToken == "token-a")
    #expect(store.pendingGrantData(id: "claude:fp-1") != nil)
  }

  @Test func aLateLinkedFetchMirrorsTheGrantAcceptedByAnEarlierLiveRefresh() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    )
    let source = ProviderCredentialSource.claudeKeychain(service: "Test-Live-Claude")
    let live = KeychainSlot(
      claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    )
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "new-tok",
      refreshToken: "ref-2",
      expiresAt: Date(timeIntervalSince1970: 100_000)
    )))
    let coordinator = ClaudeTokenRefreshCoordinator()
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
      persister: ClaudeCredentialsWriter(
        keychainRead: { _ in live.value },
        keychainWrite: { data, _ in live.value = data },
        capturedAccounts: store
      ),
      capturedAccounts: store,
      refreshCoordinator: coordinator
    )
    let now = Date(timeIntervalSince1970: 2000)

    // The unlinked dashboard fetch wins and rotates the live source first.
    _ = try await strategy.fetch(ProviderFetchContext(provider: .claude, now: now))
    var saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"), capturedAccounts: store
    )
    #expect(saved.accessToken == "old-tok")

    // This fetch starts after singleflight completed. The live token is fresh,
    // but the coordinator's accepted-generation proof still repairs the link.
    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: now,
      capturedRegistryID: "claude:fp-1"
    ))

    #expect(refresher.calls == ["ref-1"])
    saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"), capturedAccounts: store
    )
    #expect(saved.accessToken == "new-tok")
    #expect(saved.refreshToken == "ref-2")
  }

  @Test func linkedPendingReadFailureAbortsBeforeAnotherLiveRotation() async throws {
    let keychain = InMemoryKeychain()
    let prefix = "Test-LinkedPendingRead-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: prefix)
    try store.save(CapturedAccount(
      id: "claude:fp-1",
      provider: .claude,
      displayName: "Saved Claude",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: "Test-Live-Claude"),
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    ))
    let pending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "pending-tok", refreshToken: "ref-2"),
      previousAccessToken: "old-tok",
      consumedRefreshToken: "ref-1"
    )
    try store.savePendingGrant(JSONEncoder().encode(pending), id: "claude:fp-1")
    keychain.failReads(of: "\(prefix).pending.claude:fp-1")
    let source = ProviderCredentialSource.claudeKeychain(service: "Test-Live-Claude")
    let live = KeychainSlot(
      claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    )
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "newer-tok",
      refreshToken: "ref-3"
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
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )

    await #expect(throws: InMemoryKeychain.InjectedFailure.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: Date(timeIntervalSince1970: 2000),
        capturedRegistryID: "claude:fp-1"
      ))
    }
    #expect(refresher.calls.isEmpty)
  }

  @Test func savedPendingReadFailureDoesNotExchangeThePossiblyConsumedToken() async throws {
    let keychain = InMemoryKeychain()
    let prefix = "Test-SavedPendingRead-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: prefix)
    try store.save(CapturedAccount(
      id: "claude:fp-1",
      provider: .claude,
      displayName: "Saved Claude",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: "Claude Code-credentials"),
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    ))
    let pending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "pending-tok", refreshToken: "ref-2"),
      previousAccessToken: "old-tok",
      consumedRefreshToken: "ref-1"
    )
    try store.savePendingGrant(JSONEncoder().encode(pending), id: "claude:fp-1")
    keychain.failReads(of: "\(prefix).pending.claude:fp-1")
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "newer-tok",
      refreshToken: "ref-3"
    )))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      account: claudeRegistryAccount()
    ))

    #expect(refresher.calls.isEmpty)
  }
}
