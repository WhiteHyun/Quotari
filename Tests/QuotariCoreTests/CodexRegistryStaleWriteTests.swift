import Foundation
@testable import QuotariCore
import Testing

/// The refresh transaction's stale-write resolution: what wins when the
/// registry is rewritten while a refreshed pair is in hand or queued.
struct CodexRegistryStaleWriteTests {
  @Test func anObsoleteStashRestartsAgainstTheStoredGeneration() async throws {
    // A queued pair's write is rejected because a re-capture replaced the
    // registry mid-transaction. The refresh must then exchange the newly
    // stored generation's token — never resubmit the consumed old one.
    let expiredOld = codexJWT(claims: ["exp": 1000])
    let expiredRecaptured = codexJWT(claims: ["exp": 1500])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(payload: codexAuthPayload(accessToken: expiredOld, refreshToken: "ref-1"))
    let coordinator = CodexTokenRefreshCoordinator()
    await coordinator.rememberUnpersisted(
      CodexPendingGrant(
        grant: CodexTokenGrant(accessToken: "queued-tok", refreshToken: "queued-ref"),
        previousAccessToken: expiredOld,
        consumedRefreshToken: "ref-1"
      ),
      registryID: "codex:acct-1"
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-3"))
    )
    let persister = RecaptureSimulatingPersister(
      store: store,
      recapturedPayload: codexAuthPayload(accessToken: expiredRecaptured, refreshToken: "ref-2")
    )
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls == ["ref-2"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-3")
    #expect(await coordinator.takeUnpersisted(registryID: "codex:acct-1") == nil)
  }

  @Test func aStashSupersedesAStoredPairRidingTheConsumedToken() async throws {
    // The stored pair was rewritten (its access token differs, so the queued
    // write is stale) but still carries the refresh token the queued grant's
    // exchange consumed. The grant supersedes that pair; re-submitting the
    // consumed token to the endpoint would be the one wrong move.
    let stored = codexJWT(claims: ["exp": 1500])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(payload: codexAuthPayload(accessToken: stored, refreshToken: "ref-1"))
    let coordinator = CodexTokenRefreshCoordinator()
    await coordinator.rememberUnpersisted(
      CodexPendingGrant(
        grant: CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"),
        previousAccessToken: codexJWT(claims: ["exp": 1000]),
        consumedRefreshToken: "ref-1"
      ),
      registryID: "codex:acct-1"
    )
    let refresher = StubCodexRefresher(result: .failure(CodexTokenRefreshError.malformedResponse))
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
      refresher: refresher,
      persister: CodexCredentialsWriter(capturedAccounts: store),
      capturedAccounts: store,
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls.isEmpty)
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)")
  }

  @Test func aNonRotatingStashNeverClobbersAndExchangesSafely() async throws {
    // The queued grant's exchange did NOT rotate the token, so the stored
    // pair — possibly a newer concurrent write — can still refresh itself.
    // It must never be overwritten with the queued pair; a fresh exchange
    // of the still-alive token is the safe way forward.
    let storedExpired = codexJWT(claims: ["exp": 1500])
    let exchanged = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: storedExpired, refreshToken: "ref-1")
    )
    let coordinator = CodexTokenRefreshCoordinator()
    await coordinator.rememberUnpersisted(
      CodexPendingGrant(
        grant: CodexTokenGrant(accessToken: "stale-queued-tok"),
        previousAccessToken: codexJWT(claims: ["exp": 1000]),
        consumedRefreshToken: "ref-1"
      ),
      registryID: "codex:acct-1"
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: exchanged))
    )
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: refresher,
      persister: CodexCredentialsWriter(capturedAccounts: store),
      capturedAccounts: store,
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls == ["ref-1"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == exchanged)
    #expect(saved.refreshToken == "ref-1")
  }

  @Test func aRotatedGrantSupersedesAConcurrentWriteRidingTheConsumedToken() async throws {
    // A concurrent write lands between the exchange and its write-back, but
    // still rides the refresh token the exchange just rotated away — that
    // pair can never refresh again, so the grant must replace it rather
    // than being discarded.
    let expiredOld = codexJWT(claims: ["exp": 1000])
    let expiredConcurrent = codexJWT(claims: ["exp": 1500])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: expiredOld, refreshToken: "ref-1")
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let persister = RecaptureSimulatingPersister(
      store: store,
      recapturedPayload: codexAuthPayload(accessToken: expiredConcurrent, refreshToken: "ref-1")
    )
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls == ["ref-1"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)")
  }

  @Test func aConcurrentDifferentGenerationWriteWinsOverTheExchange() async throws {
    // The concurrent write is a genuinely different generation (a re-login):
    // its pair is the truth, the exchange's grant is discarded.
    let expiredOld = codexJWT(claims: ["exp": 1000])
    let freshRecaptured = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: expiredOld, refreshToken: "ref-1")
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: "discarded-tok", refreshToken: "ref-2"))
    )
    let persister = RecaptureSimulatingPersister(
      store: store,
      recapturedPayload: codexAuthPayload(accessToken: freshRecaptured, refreshToken: "ref-9")
    )
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls == ["ref-1"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == freshRecaptured)
    #expect(saved.refreshToken == "ref-9")
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(freshRecaptured)")
  }

  @Test func aNonRotatingGrantYieldsToAFreshConcurrentWrite() async throws {
    // Same still-valid token, but the exchange didn't rotate it: the fresh
    // concurrent write stays stored (it can refresh itself later) and also
    // serves the fetch.
    let expiredOld = codexJWT(claims: ["exp": 1000])
    let freshConcurrent = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: expiredOld, refreshToken: "ref-1")
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: "discarded-tok"))
    )
    let persister = RecaptureSimulatingPersister(
      store: store,
      recapturedPayload: codexAuthPayload(accessToken: freshConcurrent, refreshToken: "ref-1")
    )
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls == ["ref-1"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == freshConcurrent)
    #expect(saved.refreshToken == "ref-1")
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(freshConcurrent)")
  }
}

struct CodexRegistryDurableRebaseTests {
  @Test func aFailedSupersedingWriteKeepsTheOriginalDurableGrant() async throws {
    // The durable grant must survive when rebasing it onto the stored pair
    // fails both the registry write and the replacement pending-grant write.
    // Otherwise quitting here loses the only refresh token that still works.
    let stored = codexJWT(claims: ["exp": 1500])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let keychain = InMemoryKeychain()
    let service = "Test-CodexDurableRebase-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: service)
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Saved",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: codexAuthPayload(accessToken: stored, refreshToken: "ref-1")
    ))
    let pending = CodexPendingGrant(
      grant: CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"),
      previousAccessToken: codexJWT(claims: ["exp": 1000]),
      consumedRefreshToken: "ref-1"
    )
    try store.savePendingGrant(JSONEncoder().encode(pending), id: "codex:acct-1")
    keychain.failWrites(of: "\(service).codex:acct-1")
    keychain.failWrites(of: "\(service).pending.codex:acct-1")
    let coordinator = CodexTokenRefreshCoordinator()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: StubCodexRefresher(result: .failure(CodexTokenRefreshError.malformedResponse)),
      capturedAccounts: store,
      refreshCoordinator: coordinator
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    let loadedDurableData = try store.loadPendingGrantData(id: "codex:acct-1")
    let durableData = try #require(loadedDurableData)
    #expect(try JSONDecoder().decode(CodexPendingGrant.self, from: durableData) == pending)
    let rebased = await coordinator.takeUnpersisted(registryID: "codex:acct-1")
    #expect(rebased?.previousAccessToken == stored)
  }
}

/// Reread failures after a stale write must not lose the only working pair.
struct CodexRegistryRereadFailureTests {
  @Test func aRereadFailureAfterAStaleWriteKeepsTheGrantQueued() async throws {
    // The write is rejected as stale and the follow-up reread fails too: the
    // grant may hold the only refresh token that still works, so it must
    // stay queued — the next fetch retries the write, with no new exchange.
    let expired = codexJWT(claims: ["exp": 1000])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let keychain = InMemoryKeychain()
    let service = "Test-Blind-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: service)
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Saved",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/old.json"),
      payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1")
    ))
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let blindService = "\(service).codex:acct-1"
    let persister = BlindingPersister(store: store, keychain: keychain, blindService: blindService)
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )
    let context = ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    )

    _ = try await strategy.fetch(context)
    let firstRequest = try #require(recorder.requests.first)
    #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)")

    keychain.stopFailing(blindService)
    _ = try await strategy.fetch(context)

    #expect(refresher.calls == ["ref-1"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
  }
}
