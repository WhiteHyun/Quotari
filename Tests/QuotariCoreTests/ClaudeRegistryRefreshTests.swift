import Foundation
@testable import QuotariCore
import Testing

private let usageJSON = #"""
{"five_hour": { "utilization": 32, "resets_at": "2026-01-07T00:00:00+00:00" }}
"""#

private func claudePayload(accessToken: String, refreshToken: String, expiresAt: TimeInterval) -> Data {
  Data(#"""
  {"claudeAiOauth": {"accessToken": "\#(accessToken)", "refreshToken": "\#(refreshToken)",
                     "expiresAt": \#(Int(expiresAt * 1000))}}
  """#.utf8)
}

private func makeClaudeRegistryStore(payload: Data) throws -> CapturedAccountStore {
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

private func claudeRegistryAccount() -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Saved in Quotari",
    credentialSource: .quotariRegistry(id: "claude:fp-1")
  )
}

/// Delegates to the real writer after a scripted number of injected failures.
private final class FlakyClaudePersister: ClaudeCredentialPersisting, @unchecked Sendable {
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
private final class BlindingClaudePersister: ClaudeCredentialPersisting, @unchecked Sendable {
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
struct ClaudeRegistryRefreshTests {
  @Test func savedAccountRefreshesItsExpiredTokenAndPersistsThePair() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    )
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "new-tok",
      refreshToken: "ref-2",
      expiresAt: Date(timeIntervalSince1970: 100_000)
    )))
    let recorder = RefreshStubTransport.Recorder()
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON, recorder: recorder),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      account: claudeRegistryAccount()
    ))

    #expect(refresher.calls == ["ref-1"])
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-tok")
    let saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == "new-tok")
    #expect(saved.refreshToken == "ref-2")
  }

  @Test func aPairThatFailedToPersistIsRetriedInsteadOfBurningTheTokenAgain() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    )
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "new-tok",
      refreshToken: "ref-2",
      expiresAt: Date(timeIntervalSince1970: 100_000)
    )))
    let persister = FlakyClaudePersister(inner: ClaudeCredentialsWriter(capturedAccounts: store), failures: 1)
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )
    let context = ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      account: claudeRegistryAccount()
    )

    // First fetch: exchange succeeds, write-back fails — served from memory,
    // registry still holds the consumed refresh token.
    _ = try await strategy.fetch(context)
    var saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == "old-tok")

    // Second fetch: the queued pair is written, with no second exchange that
    // would submit the already-burned refresh token.
    _ = try await strategy.fetch(context)

    #expect(refresher.calls == ["ref-1"])
    saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == "new-tok")
    #expect(saved.refreshToken == "ref-2")
  }

  @Test func cliOwnedSourcesAreNotQueuedOnPersistFailure() async throws {
    // CLI-owned sources have Claude Code as a co-owner that heals its own
    // rotations; queuing our grant could later overwrite its fresher pair.
    let coordinator = ClaudeTokenRefreshCoordinator()
    let source = ProviderCredentialSource.claudeCredentialsFile(
      path: "/missing/\(UUID().uuidString).json"
    )
    let resolved = ResolvedClaudeCredentials(
      credentials: ClaudeCredentials(
        accessToken: "old-tok",
        refreshToken: "ref-1",
        expiresAt: Date(timeIntervalSince1970: 1000)
      ),
      source: source
    )
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON),
      resolveCredentials: { resolved },
      refresher: StubRefresher(result: .success(ClaudeTokenGrant(accessToken: "new-tok"))),
      persister: RecordingPersister(error: FlakyClaudePersister.InjectedFailure()),
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000)
    ))

    #expect(await coordinator.takeUnpersisted(sourceID: source.stableID) == nil)
  }

  @Test func aRereadFailureAfterAStaleWriteKeepsTheGrantQueued() async throws {
    let keychain = InMemoryKeychain()
    let service = "Test-ClaudeBlind-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: service)
    try store.save(CapturedAccount(
      id: "claude:fp-1",
      provider: .claude,
      displayName: "Saved Claude",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: "Claude Code-credentials"),
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    ))
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "new-tok",
      refreshToken: "ref-2",
      expiresAt: Date(timeIntervalSince1970: 100_000)
    )))
    let blindService = "\(service).claude:fp-1"
    let persister = BlindingClaudePersister(store: store, keychain: keychain, blindService: blindService)
    let recorder = RefreshStubTransport.Recorder()
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON, recorder: recorder),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )
    let context = ProviderFetchContext(
      provider: .claude,
      now: Date(timeIntervalSince1970: 2000),
      account: claudeRegistryAccount()
    )

    _ = try await strategy.fetch(context)
    let firstRequest = try #require(recorder.requests.first)
    #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer new-tok")

    keychain.stopFailing(blindService)
    _ = try await strategy.fetch(context)

    #expect(refresher.calls == ["ref-1"])
    let saved = try ClaudeCredentialsStore.load(
      source: .quotariRegistry(id: "claude:fp-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == "new-tok")
    #expect(saved.refreshToken == "ref-2")
  }
}
