import Foundation
@testable import QuotariCore
import Testing

struct ClaudeReviewFollowupTests {
  @Test func aDeniedTokenWithAnInvalidRefreshGrantRequiresLogin() async throws {
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "revoked-tok", refreshToken: "ref-1", expiresAt: 100_000)
    )
    let refresher = StubRefresher(result: .failure(
      ClaudeTokenRefreshError.reauthenticationRequired
    ))
    let recorder = RefreshStubTransport.Recorder()
    let strategy = ClaudeUsageStrategy(
      transport: TokenRoutedTransport(deniedToken: "revoked-tok", json: usageJSON, recorder: recorder),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator()
    )

    do {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: Date(timeIntervalSince1970: 2000),
        account: claudeRegistryAccount()
      ))
      Issue.record("Expected reauthentication to be required")
    } catch let error as ClaudeTokenRefreshError {
      #expect(error.requiresReauthentication)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(refresher.calls == ["ref-1"])
    #expect(recorder.requests.count == 1)
  }

  @Test func aVerifiedTokenRotationCarriesItsActiveCooldown() async throws {
    let now = Date(timeIntervalSince1970: 2000)
    let store = try makeClaudeRegistryStore(
      payload: claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 2000)
    )
    let refresher = StubRefresher(result: .success(ClaudeTokenGrant(
      accessToken: "new-tok",
      refreshToken: "ref-2",
      expiresAt: Date(timeIntervalSince1970: 100_000)
    )))
    let recorder = RefreshStubTransport.Recorder()
    let gate = ClaudeUsageRateLimitGate(now: { now })
    await gate.recordRateLimit(for: "old-tok", retryAfter: now.addingTimeInterval(300))
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON, recorder: recorder),
      refresher: refresher,
      capturedAccounts: store,
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      rateLimitGate: gate
    )

    await #expect(throws: ProviderHTTPError.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: now,
        account: claudeRegistryAccount(),
        interaction: .background
      ))
    }

    #expect(await gate.blockedUntil(for: "new-tok", now: now) == now.addingTimeInterval(300))
    #expect(recorder.requests.isEmpty)
  }

  @Test func aFreshSameGenerationStaleWriterCarriesTheCooldown() async throws {
    try await assertStaleWriterCarriesCooldown(
      writerExpiresAt: 100_000,
      expectedAccessToken: "writer-tok"
    )
  }

  @Test func anExpiredSameGenerationStaleWriterCarriesTheCooldownToTheGrant() async throws {
    try await assertStaleWriterCarriesCooldown(
      writerExpiresAt: 1000,
      expectedAccessToken: "grant-tok"
    )
  }

  private func assertStaleWriterCarriesCooldown(
    writerExpiresAt: TimeInterval,
    expectedAccessToken: String
  ) async throws {
    let now = Date(timeIntervalSince1970: 2000)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-stale-writer-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try claudePayload(
      accessToken: "old-tok",
      refreshToken: "ref-1",
      expiresAt: 1000
    ).write(to: url)
    let source = ProviderCredentialSource.claudeCredentialsFile(path: url.path)
    let recorder = RefreshStubTransport.Recorder()
    let gate = ClaudeUsageRateLimitGate(now: { now })
    await gate.recordRateLimit(for: "old-tok", retryAfter: now.addingTimeInterval(300))
    let refresher = StubRefresher(
      result: .success(ClaudeTokenGrant(accessToken: "grant-tok")),
      onRefresh: {
        try? claudePayload(
          accessToken: "writer-tok",
          refreshToken: "ref-1",
          expiresAt: writerExpiresAt
        ).write(to: url)
      }
    )
    let strategy = ClaudeUsageStrategy(
      transport: RefreshStubTransport(json: usageJSON, recorder: recorder),
      resolveCredentials: {
        try ResolvedClaudeCredentials(
          credentials: ClaudeCredentialsStore.load(source: source),
          source: source
        )
      },
      refresher: refresher,
      persister: RecordingPersister(error: ClaudeCredentialPersistError.staleSource),
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      rateLimitGate: gate
    )

    await #expect(throws: ProviderHTTPError.self) {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: now,
        interaction: .background
      ))
    }

    #expect(
      await gate.blockedUntil(for: expectedAccessToken, now: now) == now.addingTimeInterval(300)
    )
    #expect(recorder.requests.isEmpty)
  }
}
