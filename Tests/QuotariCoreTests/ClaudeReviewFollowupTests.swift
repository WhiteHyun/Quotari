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
}
