import Foundation
@testable import QuotariCore
import Testing

struct CodexResetCreditsParserTests {
  @Test func keepsAvailableCreditsThatExpireSoonestFirst() throws {
    // Observed response shape; values are synthetic and contain no account data.
    let data = Data("""
    {
      "credits": [
        { "id": "credit-late", "reset_type": "codex_rate_limits", "status": "available",
          "granted_at": "2027-01-01T00:00:00Z", "expires_at": "2027-02-01T00:00:00Z" },
        { "id": "credit-no-expiry", "reset_type": "codex_rate_limits", "status": "available",
          "granted_at": "2027-01-02T00:00:00Z", "expires_at": null },
        { "id": "credit-redeemed", "reset_type": "codex_rate_limits", "status": "redeemed",
          "granted_at": "2027-01-03T00:00:00Z", "expires_at": "2027-01-10T00:00:00Z" },
        { "id": "credit-soon", "reset_type": "codex_rate_limits", "status": "available",
          "granted_at": "2027-01-04T00:00:00Z", "expires_at": "2027-01-20T12:00:00Z" }
      ],
      "available_count": 3
    }
    """.utf8)

    #expect(try CodexResetCreditsParser.parse(data) == [
      ResetCreditExpiry(id: "credit-soon", expiresAt: Date(timeIntervalSince1970: 1_800_446_400)),
      ResetCreditExpiry(id: "credit-late", expiresAt: Date(timeIntervalSince1970: 1_801_440_000)),
    ])
  }
}

struct CodexResetCreditsFetchTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func readsCreditExpiriesWhenCreditsAreAvailable() async throws {
    let transport = RoutingTransport(routes: [
      "/backend-api/wham/usage": (200, usageJSON(availableResetCredits: 2)),
      "/backend-api/wham/rate-limit-reset-credits": (200, """
      { "credits": [ { "id": "credit-1", "reset_type": "codex_rate_limits", "status": "available",
        "granted_at": "2027-01-01T00:00:00Z", "expires_at": "2027-01-20T12:00:00Z" } ],
        "available_count": 2 }
      """),
    ])
    let strategy = CodexUsageStrategy(
      transport: transport,
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: "acct-1") }
    )

    let result = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: now))

    #expect(result.usage.resetCreditExpiries == [
      ResetCreditExpiry(id: "credit-1", expiresAt: Date(timeIntervalSince1970: 1_800_446_400)),
    ])
    let listRequest = try #require(transport.requests.last)
    #expect(listRequest.url?.path == "/backend-api/wham/rate-limit-reset-credits")
    #expect(listRequest.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(listRequest.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-1")
  }

  @Test func failedCreditListLeavesExpiriesUnknownButUsageSucceeds() async throws {
    let transport = RoutingTransport(routes: [
      "/backend-api/wham/usage": (200, usageJSON(availableResetCredits: 2)),
      "/backend-api/wham/rate-limit-reset-credits": (500, "{}"),
    ])
    let strategy = CodexUsageStrategy(
      transport: transport,
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: nil) }
    )

    let result = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: now))

    #expect(result.usage.availableResetCredits == 2)
    #expect(result.usage.resetCreditExpiries == nil)
  }

  @Test func noAvailableCreditsSkipsTheListAndReportsNone() async throws {
    let transport = RoutingTransport(routes: [
      "/backend-api/wham/usage": (200, usageJSON(availableResetCredits: 0)),
    ])
    let strategy = CodexUsageStrategy(
      transport: transport,
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: nil) }
    )

    let result = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: now))

    #expect(result.usage.resetCreditExpiries == [])
    #expect(transport.requests.map(\.url?.path) == ["/backend-api/wham/usage"])
  }
}

private func usageJSON(availableResetCredits: Int?) -> String {
  let resetCredits = availableResetCredits.map {
    #", "rate_limit_reset_credits": { "available_count": \#($0) }"#
  } ?? ""
  return """
  { "plan_type": "plus",
    "rate_limit": { "primary_window": { "used_percent": 42, "limit_window_seconds": 18000,
      "reset_after_seconds": 3600 } }\(resetCredits) }
  """
}

/// Returns a canned response per URL path and records every request.
private final class RoutingTransport: ProviderHTTPTransport, @unchecked Sendable {
  private let routes: [String: (Int, String)]
  private let lock = NSLock()
  private var recorded: [URLRequest] = []

  init(routes: [String: (Int, String)]) {
    self.routes = routes
  }

  var requests: [URLRequest] {
    lock.withLock { recorded }
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    lock.withLock { recorded.append(request) }
    let url = try #require(request.url)
    let (status, body) = routes[url.path] ?? (404, "{}")
    let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    return (Data(body.utf8), response)
  }
}
