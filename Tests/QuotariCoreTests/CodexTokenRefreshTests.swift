import Foundation
@testable import QuotariCore
import Testing

struct CodexCredentialExpiryTests {
  @Test func parsesRefreshTokenAndAccessTokenExpiry() throws {
    let accessToken = codexJWT(claims: ["exp": 1_767_744_000])
    let credentials = try CodexCredentialsStore.parse(
      codexAuthPayload(accessToken: accessToken, refreshToken: "ref-1")
    )

    #expect(credentials.refreshToken == "ref-1")
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_767_744_000))
  }

  @Test func tokensWithoutAnExpiryClaimNeverReportExpired() throws {
    let credentials = try CodexCredentialsStore.parse(codexAuthPayload(accessToken: "opaque-token"))

    #expect(credentials.expiresAt == nil)
    #expect(!credentials.isExpired(now: .distantFuture))
  }

  @Test func expiryHonorsLeeway() {
    let expiresAt = Date(timeIntervalSince1970: 1_767_744_000)
    let credentials = CodexCredentials(accessToken: "tok", accountID: nil, expiresAt: expiresAt)

    #expect(!credentials.isExpired(now: expiresAt.addingTimeInterval(-120)))
    #expect(credentials.isExpired(now: expiresAt.addingTimeInterval(-30)))
    #expect(credentials.isExpired(now: expiresAt.addingTimeInterval(60)))
  }
}

struct CodexTokenRefresherTests {
  @Test func sendsRefreshGrantMirroringCodexCLI() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(
      json: #"{"access_token": "new-tok", "refresh_token": "new-ref", "id_token": "new-id"}"#,
      recorder: recorder
    )

    let grant = try await CodexTokenRefresher(transport: transport).refresh(refreshToken: "old-ref")

    let request = try #require(recorder.requests.first)
    #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
    #expect(body == [
      "client_id": CodexTokenRefresher.clientID,
      "grant_type": "refresh_token",
      "refresh_token": "old-ref",
    ])
    #expect(grant == CodexTokenGrant(accessToken: "new-tok", refreshToken: "new-ref", idToken: "new-id"))
  }

  @Test func emptyRotatedFieldsAreTreatedAsOmitted() async throws {
    let transport = RefreshStubTransport(json: #"{"access_token": "new-tok", "refresh_token": ""}"#)

    let grant = try await CodexTokenRefresher(transport: transport).refresh(refreshToken: "ref")

    #expect(grant.refreshToken == nil)
    #expect(grant.idToken == nil)
  }

  @Test func malformedResponseThrows() async {
    let transport = RefreshStubTransport(json: #"{"token_type": "Bearer"}"#)
    await #expect(throws: CodexTokenRefreshError.self) {
      _ = try await CodexTokenRefresher(transport: transport).refresh(refreshToken: "ref")
    }
  }

  @Test func rejectedRefreshSurfacesHTTPError() async {
    let transport = RefreshStubTransport(json: #"{"error": "invalid_grant"}"#, status: 401)
    await #expect(throws: ProviderHTTPError.self) {
      _ = try await CodexTokenRefresher(transport: transport).refresh(refreshToken: "ref")
    }
  }
}

struct CodexRegistryRefreshStrategyTests {
  @Test func savedAccountRefreshesItsExpiredTokenAndPersistsThePair() async throws {
    let expired = codexJWT(claims: ["exp": 1000])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1"))
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
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
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)")
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
  }

  @Test func savedAccountWithALiveTokenIsNotRefreshed() async throws {
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(payload: codexAuthPayload(accessToken: fresh, refreshToken: "ref-1"))
    let refresher = StubCodexRefresher(result: .failure(CodexTokenRefreshError.malformedResponse))
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

  @Test func liveCredentialsAreNeverRefreshedEvenWhenExpired() async throws {
    let expired = codexJWT(claims: ["exp": 1000])
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: "should-not-be-used"))
    )
    let recorder = RefreshStubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: codexUsageStubJSON, recorder: recorder),
      loadCredentials: {
        CodexCredentials(
          accessToken: expired,
          accountID: "acct-1",
          refreshToken: "ref-1",
          expiresAt: Date(timeIntervalSince1970: 1000)
        )
      },
      refresher: refresher,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .codex,
      now: Date(timeIntervalSince1970: 2000)
    ))

    #expect(refresher.calls.isEmpty)
    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(expired)")
  }

  @Test func aPairThatFailedToPersistIsRetriedInsteadOfBurningTheTokenAgain() async throws {
    let expired = codexJWT(claims: ["exp": 1000])
    let fresh = codexJWT(claims: ["exp": 100_000])
    let store = try makeCodexRegistryStore(payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1"))
    let refresher = StubCodexRefresher(
      result: .success(CodexTokenGrant(accessToken: fresh, refreshToken: "ref-2"))
    )
    let persister = FlakyPersister(inner: CodexCredentialsWriter(capturedAccounts: store), failures: 1)
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

    // First fetch: the exchange succeeds but the write-back fails — the fetch
    // is served from the in-memory pair, and the registry still holds the old
    // (now server-side-consumed) refresh token.
    _ = try await strategy.fetch(context)
    var saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == expired)

    // Second fetch: the queued pair is written, with no second exchange that
    // would submit the already-burned refresh token.
    _ = try await strategy.fetch(context)

    #expect(refresher.calls == ["ref-1"])
    #expect(persister.callCount == 2)
    saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == fresh)
    #expect(saved.refreshToken == "ref-2")
    #expect(recorder.requests.allSatisfy {
      $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(fresh)"
    })
  }

  @Test func failedRefreshFallsBackToTheStoredTokenAndKeepsThePayload() async throws {
    let expired = codexJWT(claims: ["exp": 1000])
    let store = try makeCodexRegistryStore(payload: codexAuthPayload(accessToken: expired, refreshToken: "ref-1"))
    let refresher = StubCodexRefresher(result: .failure(ProviderHTTPError.status(503)))
    let strategy = CodexUsageStrategy(
      transport: RefreshStubTransport(json: "{}", status: 401),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: CodexTokenRefreshCoordinator()
    )

    await #expect(throws: ProviderHTTPError.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .codex,
        now: Date(timeIntervalSince1970: 2000),
        account: codexRegistryAccount()
      ))
    }

    // Once before the request (expired) and once forced by the 401 — both
    // fail, the stored pair survives untouched for the next attempt.
    #expect(refresher.calls == ["ref-1", "ref-1"])
    let saved = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: store
    )
    #expect(saved.accessToken == expired)
    #expect(saved.refreshToken == "ref-1")
  }
}
