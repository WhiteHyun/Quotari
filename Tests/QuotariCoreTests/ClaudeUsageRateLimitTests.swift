import Foundation
@testable import QuotariCore
import Testing

struct ClaudeUsageRateLimitTests {
  @Test func parsesRetryAfterHTTPDate() async throws {
    let expected = try #require(
      ISO8601DateFormatter().date(from: "2030-10-21T07:28:00Z")
    )
    let usageURL = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let transport = SequencedClaudeUsageTransport([
      .init(
        status: 429,
        headers: ["Retry-After": "Mon, 21 Oct 2030 07:28:00 GMT"]
      ),
    ])

    do {
      _ = try await transport.getJSON(
        url: usageURL,
        bearer: "token"
      )
      Issue.record("Expected a rate-limit error")
    } catch let ProviderHTTPError.rateLimited(retryAfter) {
      #expect(retryAfter == expected)
    }
  }

  @Test func parsesRetryAfterSeconds() async throws {
    let usageURL = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
    let before = Date()
    let transport = SequencedClaudeUsageTransport([
      .init(status: 429, headers: ["Retry-After": "120"]),
    ])

    do {
      _ = try await transport.getJSON(url: usageURL, bearer: "token")
      Issue.record("Expected a rate-limit error")
    } catch let ProviderHTTPError.rateLimited(retryAfter) {
      let parsed = try #require(retryAfter)
      #expect(abs(parsed.timeIntervalSince(before) - 120) < 1)
    }
  }

  @Test func backgroundCooldownCanBeBypassedAndClearedByUserRefresh() async throws {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let transport = SequencedClaudeUsageTransport([
      .init(status: 429),
      .init(status: 200, body: Self.usageJSON),
      .init(status: 200, body: Self.usageJSON),
    ])
    let gate = ClaudeUsageRateLimitGate(defaultCooldown: 300, now: { now })
    let strategy = Self.strategy(transport: transport, gate: gate)

    do {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: now,
        interaction: .background
      ))
      Issue.record("Expected the endpoint's 429")
    } catch let ProviderHTTPError.rateLimited(retryAfter) {
      #expect(retryAfter == nil)
    }
    #expect(await transport.requestCount == 1)

    do {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: now.addingTimeInterval(60),
        interaction: .background
      ))
      Issue.record("Expected the stored cooldown")
    } catch let ProviderHTTPError.rateLimited(retryAfter) {
      #expect(retryAfter == now.addingTimeInterval(300))
    }
    #expect(await transport.requestCount == 1)

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: now.addingTimeInterval(60),
      interaction: .userInitiated
    ))
    #expect(await transport.requestCount == 2)

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: now.addingTimeInterval(61),
      interaction: .background
    ))
    #expect(await transport.requestCount == 3)
  }

  @Test func expiredCooldownUsesCurrentGateClockInsteadOfFetchSnapshot() async throws {
    let contextNow = Date(timeIntervalSince1970: 1_783_478_400)
    let gateNow = contextNow.addingTimeInterval(600)
    let gate = ClaudeUsageRateLimitGate(now: { gateNow })
    await gate.recordRateLimit(
      for: "token",
      retryAfter: gateNow.addingTimeInterval(-1),
      now: contextNow
    )
    let transport = SequencedClaudeUsageTransport([
      .init(status: 200, body: Self.usageJSON),
    ])
    let strategy = Self.strategy(transport: transport, gate: gate)

    _ = try await strategy.fetch(ProviderFetchContext(
      provider: .claude,
      now: contextNow,
      interaction: .background
    ))

    #expect(await transport.requestCount == 1)
  }

  @Test func fallbackCooldownStartsFromCurrentGateClock() async {
    let contextNow = Date(timeIntervalSince1970: 1_783_478_400)
    let gateNow = contextNow.addingTimeInterval(600)
    let gate = ClaudeUsageRateLimitGate(defaultCooldown: 300, now: { gateNow })
    let transport = SequencedClaudeUsageTransport([.init(status: 429)])
    let strategy = Self.strategy(transport: transport, gate: gate)

    do {
      _ = try await strategy.fetch(ProviderFetchContext(
        provider: .claude,
        now: contextNow,
        interaction: .background
      ))
      Issue.record("Expected the endpoint's 429")
    } catch let ProviderHTTPError.rateLimited(retryAfter) {
      #expect(retryAfter == nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    #expect(
      await gate.blockedUntil(for: "token", now: gateNow) == gateNow.addingTimeInterval(300)
    )
  }

  @Test func zeroOrElapsedRetryAfterDoesNotImposeDefaultCooldown() async {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let gate = ClaudeUsageRateLimitGate(defaultCooldown: 300, now: { now })
    await gate.recordRateLimit(for: "token", retryAfter: nil)
    #expect(
      await gate.blockedUntil(for: "token", now: now) == now.addingTimeInterval(300)
    )

    await gate.recordRateLimit(for: "token", retryAfter: now)

    #expect(await gate.blockedUntil(for: "token", now: now) == nil)
  }

  @Test func persistedCooldownSurvivesGateRecreation() async throws {
    let suiteName = "quotari-rate-limit-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let blockedUntil = now.addingTimeInterval(120)

    let first = ClaudeUsageRateLimitGate(persistence: .suite(suiteName))
    await first.recordRateLimit(for: "secret-token", retryAfter: blockedUntil, now: now)

    let relaunched = ClaudeUsageRateLimitGate(persistence: .suite(suiteName))
    #expect(await relaunched.blockedUntil(for: "secret-token", now: now) == blockedUntil)
    #expect(!defaults.dictionaryRepresentation().keys.contains { $0.contains("secret-token") })
    await relaunched.recordSuccess(for: "secret-token")
    let cleared = ClaudeUsageRateLimitGate(persistence: .suite(suiteName))
    #expect(await cleared.blockedUntil(for: "secret-token", now: now) == nil)
  }

  @Test func rateLimitCooldownIsIsolatedByCredential() async throws {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let transport = SequencedClaudeUsageTransport([
      .init(status: 429),
      .init(status: 200, body: Self.usageJSON),
    ])
    let gate = ClaudeUsageRateLimitGate(defaultCooldown: 300, now: { now })
    let first = Self.strategy(transport: transport, gate: gate, accessToken: "token-a")
    let second = Self.strategy(transport: transport, gate: gate, accessToken: "token-b")

    await #expect(throws: ProviderHTTPError.self) {
      _ = try await first.fetch(ProviderFetchContext(provider: .claude, now: now))
    }
    _ = try await second.fetch(ProviderFetchContext(provider: .claude, now: now))
    await #expect(throws: ProviderHTTPError.self) {
      _ = try await first.fetch(ProviderFetchContext(
        provider: .claude,
        now: now.addingTimeInterval(60)
      ))
    }

    #expect(await transport.requestCount == 2)
  }

  @Test func invalidGrantTakesPriorityOverAUsageRateLimit() async {
    let now = Date(timeIntervalSince1970: 1_783_478_400)
    let transport = SequencedClaudeUsageTransport([.init(status: 429)])
    let strategy = ClaudeUsageStrategy(
      transport: transport,
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(
            accessToken: "expired-token",
            refreshToken: "invalid-refresh-token",
            expiresAt: now.addingTimeInterval(-60)
          ),
          source: .claudeEnvironment(name: "QUOTARI_INVALID_GRANT_TEST")
        )
      },
      refresher: StubRefresher(result: .failure(
        ClaudeTokenRefreshError.reauthenticationRequired
      )),
      refreshCoordinator: ClaudeTokenRefreshCoordinator(),
      rateLimitGate: ClaudeUsageRateLimitGate()
    )

    do {
      _ = try await strategy.fetch(ProviderFetchContext(provider: .claude, now: now))
      Issue.record("Expected the terminal refresh error")
    } catch let error as ClaudeTokenRefreshError {
      #expect(error.requiresReauthentication)
      #expect(error.localizedDescription.contains("login expired"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
    #expect(await transport.requestCount == 0)
  }

  @Test func rateLimitMessageExplainsAutomaticAndManualRetry() {
    let message = ProviderHTTPError.rateLimited(retryAfter: nil).localizedDescription
    #expect(message.contains("retry automatically"))
    #expect(message.contains("Refresh"))
  }

  private static func strategy(
    transport: any ProviderHTTPTransport,
    gate: ClaudeUsageRateLimitGate,
    accessToken: String = "token"
  ) -> ClaudeUsageStrategy {
    ClaudeUsageStrategy(
      transport: transport,
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(accessToken: accessToken),
          source: .claudeEnvironment(name: "QUOTARI_TEST")
        )
      },
      rateLimitGate: gate
    )
  }

  private static let usageJSON = """
  {
    "five_hour": { "utilization": 20, "resets_at": "2030-10-21T08:28:00Z" },
    "seven_day": { "utilization": 30, "resets_at": "2030-10-28T07:28:00Z" }
  }
  """
}

private actor SequencedClaudeUsageTransport: ProviderHTTPTransport {
  struct Response: Sendable {
    let status: Int
    let body: String
    let headers: [String: String]

    init(
      status: Int,
      body: String = "{}",
      headers: [String: String] = [:]
    ) {
      self.status = status
      self.body = body
      self.headers = headers
    }
  }

  private var responses: [Response]
  private(set) var requestCount = 0

  init(_ responses: [Response]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requestCount += 1
    let response = responses.removeFirst()
    guard let url = request.url,
          let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: response.headers
          )
    else { throw URLError(.badServerResponse) }
    return (Data(response.body.utf8), httpResponse)
  }
}
