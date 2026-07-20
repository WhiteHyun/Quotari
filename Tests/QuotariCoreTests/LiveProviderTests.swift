import Foundation
@testable import QuotariCore
import Testing

/// A canned HTTP transport: returns a fixed body/status and records requests.
private struct StubTransport: ProviderHTTPTransport {
  let body: Data
  let status: Int
  let recorder: Recorder?

  final class Recorder: @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) {
      requests.append(request)
    }
  }

  init(json: String, status: Int = 200, recorder: Recorder? = nil) {
    body = Data(json.utf8)
    self.status = status
    self.recorder = recorder
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    recorder?.record(request)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: status,
      httpVersion: nil,
      headerFields: nil
    )!
    return (body, response)
  }
}

private let codexJSON = """
{
  "plan_type": "pro",
  "rate_limit": {
    "primary_window": { "used_percent": 73, "reset_at": 1767744000, "limit_window_seconds": 18000 },
    "secondary_window": { "used_percent": 34, "reset_at": 1768262400, "limit_window_seconds": 604800 }
  },
  "additional_rate_limits": [
    {
      "limit_name": "GPT-5.3-Codex-Spark",
      "rate_limit": {
        "primary_window": { "used_percent": 1, "reset_after_seconds": 18000, "limit_window_seconds": 18000 },
        "secondary_window": { "used_percent": 2, "reset_at": 1768262400, "limit_window_seconds": 604800 }
      }
    }
  ]
}
"""

private let codexLegacyJSON = """
{
  "plan": "Pro 5x",
  "account_email": "you@example.com",
  "rate_limits": [
    { "window": "five_hour", "used_percent": 73, "resets_in_seconds": 6240 },
    { "window": "seven_day", "used_percent": 34 },
    { "window": "seven_day_spark", "used_percent": 1, "label": "Codex Spark Weekly" }
  ]
}
"""

private let claudeJSON = """
{
  "five_hour": { "utilization": 32, "resets_at": "2026-01-07T00:00:00.573174+00:00" },
  "seven_day": { "utilization": 76, "resets_at": "2026-01-12T00:00:00.573208+00:00" },
  "extra_usage": { "is_enabled": true, "monthly_limit": 100, "used_credits": 12.5, "utilization": 12.5 },
  "spend": { "used": { "amount_minor": 370, "currency": "USD", "exponent": 2 } },
  "limits": [
    { "kind": "weekly", "group": "weekly", "percent": 76, "resets_at": "2026-01-12T00:00:00.573208+00:00", "is_active": true },
    {
      "kind": "weekly_scoped",
      "group": "weekly",
      "percent": 12,
      "reset_after_seconds": 3600,
      "is_active": false,
      "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" } }
    }
  ]
}
"""

struct CodexUsageTests {
  @Test func parsesLiveUsageThroughMapper() async throws {
    let recorder = StubTransport.Recorder()
    let strategy = CodexUsageStrategy(
      transport: StubTransport(json: codexJSON, recorder: recorder),
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: "acct-1", email: "dev@example.com") }
    )
    let result = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: Date()))

    #expect(result.usage.plan == "Pro 20x")
    #expect(result.usage.account == "dev@example.com")
    #expect(result.usage.primary?.usedPercent == 73)
    #expect(result.usage.primary?.duration == TimeInterval(5 * 3600))
    #expect(result.usage.secondary?.usedPercent == 34)
    #expect(result.usage.extraWindows.map(\.title) == [
      "GPT-5.3-Codex-Spark 5-hour", "GPT-5.3-Codex-Spark Weekly",
    ])
    #expect(result.usage.extraWindows.first?.window.resetsAt != nil)
    #expect(result.sourceLabel == "Codex")

    let request = try #require(recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    #expect(request.value(forHTTPHeaderField: "chatgpt-account-id") == "acct-1")
  }

  @Test func parsesLegacyRateLimitList() async throws {
    let strategy = CodexUsageStrategy(
      transport: StubTransport(json: codexLegacyJSON),
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: nil) }
    )
    let result = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: Date()))

    #expect(result.usage.plan == "Pro 5x")
    #expect(result.usage.account == "you@example.com")
    #expect(result.usage.primary?.usedPercent == 73)
    #expect(result.usage.secondary?.usedPercent == 34)
    #expect(result.usage.extraWindows.map(\.title) == ["Codex Spark Weekly"])
  }

  @Test func unauthorizedDoesNotFallBack() async {
    let strategy = CodexUsageStrategy(
      transport: StubTransport(json: "{}", status: 401),
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: nil) }
    )
    do {
      _ = try await strategy.fetch(ProviderFetchContext(provider: .codex, now: Date()))
      Issue.record("expected unauthorized error")
    } catch {
      #expect(error is ProviderHTTPError)
      #expect(strategy.shouldFallback(on: error) == false)
    }
  }

  @Test func unavailableWithoutCredentials() async {
    let strategy = CodexUsageStrategy(
      transport: StubTransport(json: "{}"),
      loadCredentials: { throw CodexCredentialsError.notFound }
    )
    #expect(await strategy.isAvailable(ProviderFetchContext(provider: .codex, now: Date())) == false)
  }

  @Test func emptyPayloadRemainsALiveFetchFailure() async {
    // A 200 with no recognizable windows must remain a visible live-data
    // failure instead of being accepted as an empty usage snapshot.
    let live = CodexUsageStrategy(
      transport: StubTransport(json: #"{"plan":"free"}"#),
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: nil) }
    )
    let context = ProviderFetchContext(provider: .codex, now: Date())
    let result = await ProviderFetchPipeline { _ in [live] }.fetch(context)

    guard case let .failure(ProviderFetchError.emptyUsage(provider)) = result else {
      Issue.record("Expected the empty live response to fail")
      return
    }
    #expect(provider == .codex)
  }
}

struct CodexCredentialsTests {
  @Test func parsesTokenAndAccount() throws {
    let json = Data("""
    { "tokens": { "access_token": "abc", "account_id": "acct" } }
    """.utf8)
    let creds = try CodexCredentialsStore.parse(json)
    #expect(creds.accessToken == "abc")
    #expect(creds.accountID == "acct")
    #expect(creds.email == nil)
  }

  @Test func extractsEmailFromIDToken() throws {
    let claims = Data(#"{"email":"dev@example.com"}"#.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "=", with: "")
    let json = Data("""
    { "tokens": { "access_token": "abc", "id_token": "eyJhbGciOiJSUzI1NiJ9.\(claims).sig" } }
    """.utf8)
    let creds = try CodexCredentialsStore.parse(json)
    #expect(creds.email == "dev@example.com")
  }

  @Test func rejectsWorldReadableFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-codex-\(UUID().uuidString).json")
    try Data("""
    { "tokens": { "access_token": "abc" } }
    """.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

    #expect(throws: CodexCredentialsError.self) {
      try CodexCredentialsStore.load(url: url)
    }
  }
}

struct ClaudeUsageTests {
  @Test func parsesUsageWithRenamedModelWindow() async throws {
    let strategy = ClaudeUsageStrategy(
      transport: StubTransport(json: claudeJSON),
      resolveCredentials: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(
            accessToken: "tok",
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x"
          ),
          source: .claudeEnvironment(name: "QUOTARI_TEST")
        )
      }
    )
    let now = Date(timeIntervalSince1970: 1_767_744_000)
    let result = try await strategy.fetch(ProviderFetchContext(provider: .claude, now: now))

    #expect(result.usage.plan == "Max 20x")
    #expect(result.usage.primary?.usedPercent == 32)
    #expect(result.usage.primary?.resetsAt != nil)
    #expect(result.usage.secondary?.usedPercent == 76)
    #expect(result.usage.secondary?.resetsAt != nil)
    // The scoped weekly limit surfaces (despite is_active false); the unscoped
    // limits entry and extra_usage must not become windows.
    #expect(result.usage.extraWindows.map(\.title) == ["Fable only"])
    let fable = try #require(result.usage.extraWindows.first?.window)
    #expect(fable.usedPercent == 12)
    #expect(fable.resetsAt == now.addingTimeInterval(3600))
    #expect(fable.duration == TimeInterval(7 * 24 * 3600))

    let cost = try #require(result.usage.cost)
    #expect(cost.todaySpend == 3.70)
    #expect(cost.monthSpend == 3.70)
    #expect(cost.currencyCode == "USD")
    #expect(cost.sourceDescription == "Reported by provider")
    #expect(cost.hasTokenMetrics == false)
    #expect(cost.daily == [DailyCost(
      date: Calendar(identifier: .gregorian).startOfDay(for: now),
      spend: 3.70,
      tokens: 0
    )])
  }

  @Test func unavailableWithoutCredentials() async {
    let strategy = ClaudeUsageStrategy(
      transport: StubTransport(json: "{}"),
      resolveCredentials: { throw ClaudeCredentialsError.notFound }
    )
    #expect(await strategy.isAvailable(ProviderFetchContext(provider: .claude, now: Date())) == false)
  }
}

struct ClaudeCredentialsTests {
  @Test func parsesKeychainPayload() throws {
    let json = Data("""
    {
      "claudeAiOauth": {
        "accessToken": "tok",
        "refreshToken": "ref",
        "expiresAt": 1767744000000,
        "scopes": ["user:inference"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_5x"
      }
    }
    """.utf8)
    let credentials = try ClaudeCredentialsStore.parse(json)
    #expect(credentials.accessToken == "tok")
    #expect(credentials.subscriptionType == "max")
    #expect(credentials.rateLimitTier == "default_claude_max_5x")
  }

  @Test func rejectsPayloadWithoutToken() {
    #expect(throws: ClaudeCredentialsError.self) {
      try ClaudeCredentialsStore.parse(Data(#"{"claudeAiOauth":{}}"#.utf8))
    }
  }
}

struct PlanLabelTests {
  @Test func codexTiers() {
    #expect(PlanLabel.codex("pro") == "Pro 20x")
    #expect(PlanLabel.codex("pro_lite") == "Pro 5x")
    #expect(PlanLabel.codex("plus") == "Plus")
    #expect(PlanLabel.codex("free_workspace") == "Free Workspace")
    #expect(PlanLabel.codex(nil) == nil)
  }

  @Test func claudeTiers() {
    #expect(PlanLabel.claude(subscriptionType: "max", rateLimitTier: "default_claude_max_20x") == "Max 20x")
    #expect(PlanLabel.claude(subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == "Max 5x")
    #expect(PlanLabel.claude(subscriptionType: "pro", rateLimitTier: nil) == "Pro")
    #expect(PlanLabel.claude(subscriptionType: "team", rateLimitTier: "default") == "Team")
    #expect(PlanLabel.claude(subscriptionType: nil, rateLimitTier: nil) == nil)
  }
}

struct ProviderCatalogTests {
  @Test func unavailableLiveStrategyReturnsMissingCredential() async {
    let unavailableLive = CodexUsageStrategy(
      transport: StubTransport(json: "{}"),
      loadCredentials: { throw CodexCredentialsError.notFound }
    )
    let pipeline = ProviderFetchPipeline { _ in [unavailableLive] }
    let result = await pipeline.fetch(ProviderFetchContext(provider: .codex, now: Date()))

    guard case let .failure(ProviderFetchError.missingCredential(provider)) = result else {
      Issue.record("Expected a missing-credential failure")
      return
    }
    #expect(provider == .codex)
  }

  @Test func runtimeCatalogContainsOnlyOneLiveOAuthStrategyPerProvider() {
    for descriptor in ProviderRegistry.all {
      let context = ProviderFetchContext(provider: descriptor.id, now: Date())
      let strategies = descriptor.pipeline.resolveStrategies(context)

      #expect(strategies.count == 1)
      #expect(strategies.first?.kind == .oauth)
      #expect(strategies.first?.id.hasSuffix(".oauth") == true)
    }
  }

  @Test func everyProviderStillHasADescriptor() {
    #expect(ProviderRegistry.isComplete)
  }
}
