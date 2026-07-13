import Foundation
@testable import QuotariCore
import Testing

/// Saved-account recovery beyond the happy path: tokens denied before their
/// local expiry says so, and rotated pairs surviving an app relaunch.
struct CodexRegistryRecoveryTests {
  @Test func pendingReadFailureDoesNotExchangeThePossiblyConsumedToken() async throws {
    let keychain = InMemoryKeychain()
    let prefix = "Test-CodexPendingRead-\(UUID().uuidString)"
    let store = CapturedAccountStore(keychain: keychain.store, service: prefix)
    let expired = codexJWT(claims: ["exp": 1000])
    try store.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Saved Codex",
      detail: nil,
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: "/tmp/auth.json"),
      payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1")
    ))
    let pending = CodexPendingGrant(
      grant: CodexTokenGrant(accessToken: codexJWT(claims: ["exp": 100_000]), refreshToken: "ref-2"),
      previousAccessToken: expired,
      consumedRefreshToken: "ref-1"
    )
    try store.savePendingGrant(JSONEncoder().encode(pending), id: "codex:acct-1")
    keychain.failReads(of: "\(prefix).pending.codex:acct-1")
    let refresher = StubCodexRefresher(result: .success(CodexTokenGrant(
      accessToken: codexJWT(claims: ["exp": 200_000]),
      refreshToken: "ref-3"
    )))
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(refresher.calls.isEmpty)
  }

  @Test func aDeniedTokenIsRefreshedAndRetriedOnce() async throws {
    // No parseable `exp` (an opaque token) and the endpoint denies it: the
    // proactive expiry check can't help, so the 401 must trigger one forced
    // refresh and a single retry.
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: "revoked-opaque-token", refreshToken: "ref-1")
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: TokenRoutedTransport(
        deniedToken: "revoked-opaque-token",
        json: codexUsageStubJSON,
        recorder: recorder
      ),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    let result = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(result.usage.primary?.usedPercent == 73)
    #expect(refresher.calls == ["ref-1"])
    #expect(recorder.requests.count == 2)
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
  }

  @Test func aPendingGrantSurvivesARelaunch() async throws {
    // The write-back fails and the app quits before the next fetch: the
    // durable pending copy must let a fresh launch (new coordinator, empty
    // memory) heal the registry without a second exchange.
    let expired = codexJWT(claims: ["exp": 1000])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1")
    )
    let firstRefresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let firstLaunch = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: firstRefresher,
      persister: FlakyPersister(inner: CodexCredentialsWriter(capturedAccounts: store), failures: 1),
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )
    let context = ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    )
    _ = try await firstLaunch.fetch(context)
    #expect(store.pendingGrantData(id: "codex:acct-1") != nil)

    // "Relaunch": fresh coordinator, a refresher that must never be called.
    let secondRefresher = StubCodexRefresher(result: .failure(CodexTokenRefreshError.malformedResponse))
    let secondLaunch = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON),
      refresher: secondRefresher,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )
    _ = try await secondLaunch.fetch(context)

    #expect(secondRefresher.calls.isEmpty)
    #expect(store.pendingGrantData(id: "codex:acct-1") == nil)
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
  }

  @Test func aFailedWriteBackStillServesTheFreshGrantAfterA401() async throws {
    // Opaque token (no exp), denied by the endpoint, exchange succeeds but
    // the write-back fails: the retry must go out with the fresh grant, not
    // re-read the registry's old denied token and give up.
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(
      payload: codexAuthPayload(accessToken: "denied-opaque", refreshToken: "ref-1")
    )
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let persister = FlakyPersister(inner: CodexCredentialsWriter(capturedAccounts: store), failures: 1)
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: TokenRoutedTransport(deniedToken: "denied-opaque", json: codexUsageStubJSON, recorder: recorder),
      refresher: refresher,
      persister: persister,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    let result = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000),
      account: codexRegistryAccount()
    ))

    #expect(result.usage.primary?.usedPercent == 73)
    #expect(refresher.calls == ["ref-1"])
    #expect(recorder.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)")
    // The grant stays queued for the next fetch to heal the registry.
    #expect(store.pendingGrantData(id: "codex:acct-1") != nil)
  }
}
