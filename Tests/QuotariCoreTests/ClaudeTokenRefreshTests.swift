import Foundation
@testable import QuotariCore
import Testing

struct ClaudeCredentialExpiryTests {
  @Test func parsesRefreshTokenExpiryAndScopes() throws {
    let json = Data("""
    {
      "claudeAiOauth": {
        "accessToken": "tok",
        "refreshToken": "ref",
        "expiresAt": 1767744000000,
        "scopes": ["user:inference", "user:profile"],
        "subscriptionType": "max"
      }
    }
    """.utf8)

    let credentials = try ClaudeCredentialsStore.parse(json)

    #expect(credentials.refreshToken == "ref")
    #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_767_744_000))
    #expect(credentials.scopes == ["user:inference", "user:profile"])
  }

  @Test func credentialsWithoutExpiryNeverReportExpired() {
    let credentials = ClaudeCredentials(accessToken: "tok")
    #expect(!credentials.isExpired(now: .distantFuture))
  }

  @Test func expiryHonorsLeeway() {
    let expiresAt = Date(timeIntervalSince1970: 1_767_744_000)
    let credentials = ClaudeCredentials(accessToken: "tok", expiresAt: expiresAt)

    #expect(!credentials.isExpired(now: expiresAt.addingTimeInterval(-120)))
    #expect(credentials.isExpired(now: expiresAt.addingTimeInterval(-30)))
    #expect(credentials.isExpired(now: expiresAt.addingTimeInterval(60)))
  }
}

struct ClaudeTokenRefresherTests {
  @Test func sendsRefreshGrantMirroringClaudeCode() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(
      json: #"""
      {"access_token": "new-tok", "refresh_token": "new-ref", "expires_in": 3600,
       "scope": "user:inference user:profile"}
      """#,
      recorder: recorder
    )
    let now = Date(timeIntervalSince1970: 1_767_744_000)

    let grant = try await ClaudeTokenRefresher(transport: transport)
      .refresh(refreshToken: "old-ref", scopes: ["user:inference", "user:profile"], now: now)

    let request = try #require(recorder.requests.first)
    #expect(request.url == ClaudeTokenRefresher.tokenURL)
    #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
    #expect(body == [
      "grant_type": "refresh_token",
      "refresh_token": "old-ref",
      "client_id": ClaudeTokenRefresher.clientID,
      "scope": "user:inference user:profile",
    ])
    #expect(grant.accessToken == "new-tok")
    #expect(grant.refreshToken == "new-ref")
    #expect(grant.expiresAt == now.addingTimeInterval(3600))
    #expect(grant.scopes == ["user:inference", "user:profile"])
  }

  @Test func fallsBackToClaudeCodeDefaultScopes() async throws {
    let recorder = RefreshStubTransport.Recorder()
    let transport = RefreshStubTransport(json: #"{"access_token": "new-tok"}"#, recorder: recorder)

    let grant = try await ClaudeTokenRefresher(transport: transport)
      .refresh(refreshToken: "ref", scopes: [], now: Date(timeIntervalSince1970: 0))

    let request = try #require(recorder.requests.first)
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: String]
    #expect(body?["scope"] == ClaudeTokenRefresher.defaultScopes.joined(separator: " "))
    // An incomplete-but-successful response must not fabricate rotation/expiry.
    #expect(grant.refreshToken == nil)
    #expect(grant.expiresAt == nil)
  }

  @Test func emptyRotatedRefreshTokenIsTreatedAsOmitted() async throws {
    let transport = RefreshStubTransport(json: #"{"access_token": "new-tok", "refresh_token": ""}"#)

    let grant = try await ClaudeTokenRefresher(transport: transport)
      .refresh(refreshToken: "ref", scopes: [], now: Date())

    #expect(grant.refreshToken == nil)
  }

  @Test func malformedResponseThrows() async {
    let transport = RefreshStubTransport(json: #"{"token_type": "Bearer"}"#)
    await #expect(throws: ClaudeTokenRefreshError.self) {
      _ = try await ClaudeTokenRefresher(transport: transport)
        .refresh(refreshToken: "ref", scopes: [], now: Date())
    }
  }

  @Test func rejectedRefreshSurfacesHTTPError() async {
    let transport = RefreshStubTransport(json: #"{"error": "invalid_grant"}"#, status: 401)
    await #expect(throws: ProviderHTTPError.self) {
      _ = try await ClaudeTokenRefresher(transport: transport)
        .refresh(refreshToken: "ref", scopes: [], now: Date())
    }
  }
}

struct ClaudeTokenRefreshCoordinatorTests {
  private static func resolved(token: String) -> ResolvedClaudeCredentials {
    ResolvedClaudeCredentials(
      credentials: ClaudeCredentials(accessToken: token),
      source: .claudeKeychain(service: "test")
    )
  }

  @Test func concurrentCallersShareOneTransaction() async {
    let coordinator = ClaudeTokenRefreshCoordinator()
    let counter = CallCounter()
    let operation: @Sendable () async -> ClaudeRefreshResolution = {
      await counter.increment()
      try? await Task.sleep(for: .milliseconds(100))
      return ClaudeRefreshResolution(resolved: Self.resolved(token: "fresh"))
    }

    async let first = coordinator.resolve(key: "claude-keychain:test#ref-1", operation: operation)
    async let second = coordinator.resolve(key: "claude-keychain:test#ref-1", operation: operation)
    let outcomes = await [first, second]

    #expect(outcomes.map(\.resolved.credentials.accessToken) == ["fresh", "fresh"])
    #expect(await counter.count == 1)
  }

  @Test func distinctTokenGenerationsResolveIndependently() async {
    let coordinator = ClaudeTokenRefreshCoordinator()
    let counter = CallCounter()
    let operation: @Sendable () async -> ClaudeRefreshResolution = {
      await counter.increment()
      try? await Task.sleep(for: .milliseconds(50))
      return ClaudeRefreshResolution(resolved: Self.resolved(token: "fresh"))
    }

    // Same source, different refresh-token generation: never share a run.
    async let first = coordinator.resolve(key: "claude-keychain:test#ref-1", operation: operation)
    async let second = coordinator.resolve(key: "claude-keychain:test#ref-2", operation: operation)
    _ = await [first, second]

    #expect(await counter.count == 2)
  }

  @Test func anOlderTransactionFinishingLastDoesNotHideNewerAcceptedProof() async {
    let coordinator = ClaudeTokenRefreshCoordinator()
    let source = ProviderCredentialSource.claudeKeychain(service: "test")
    let olderPending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "token-b", refreshToken: "ref-b"),
      previousAccessToken: "token-a",
      consumedRefreshToken: "ref-a"
    )
    let newerPending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "token-c", refreshToken: "ref-c"),
      previousAccessToken: "token-b",
      consumedRefreshToken: "ref-b"
    )

    async let older = coordinator.resolve(key: "\(source.stableID)#ref-a") {
      try? await Task.sleep(for: .milliseconds(100))
      return ClaudeRefreshResolution(
        resolved: ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(accessToken: "token-b", refreshToken: "ref-b"),
          source: source
        ),
        acceptedGrant: olderPending
      )
    }
    async let newer = coordinator.resolve(key: "\(source.stableID)#ref-b") {
      try? await Task.sleep(for: .milliseconds(10))
      return ClaudeRefreshResolution(
        resolved: ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(accessToken: "token-c", refreshToken: "ref-c"),
          source: source
        ),
        acceptedGrant: newerPending
      )
    }
    _ = await [older, newer]

    #expect(
      await coordinator.acceptedGrant(
        sourceID: source.stableID,
        accessToken: "token-c",
        refreshToken: "ref-c"
      ) == newerPending
    )
    #expect(
      await coordinator.acceptedGrant(
        sourceID: source.stableID,
        accessToken: "token-c",
        refreshToken: "different-ref"
      ) == nil
    )
  }

  @Test func mismatchedAcceptedResolutionIsNotCached() async {
    let coordinator = ClaudeTokenRefreshCoordinator()
    let source = ProviderCredentialSource.claudeKeychain(service: "test")
    let pending = ClaudePendingGrant(
      grant: ClaudeTokenGrant(accessToken: "token-b", refreshToken: "ref-b"),
      previousAccessToken: "token-a",
      consumedRefreshToken: "ref-a"
    )

    let resolution = await coordinator.resolve(key: "mismatched") {
      ClaudeRefreshResolution(
        resolved: ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(accessToken: "token-b", refreshToken: "other-ref"),
          source: source
        ),
        acceptedGrant: pending
      )
    }

    #expect(resolution.acceptedGrant == nil)
    #expect(
      await coordinator.acceptedGrant(
        sourceID: source.stableID,
        accessToken: "token-b",
        refreshToken: "other-ref"
      ) == nil
    )
  }

  private actor CallCounter {
    private(set) var count = 0
    func increment() {
      count += 1
    }
  }
}
