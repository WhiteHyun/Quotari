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
  "limits": [
    { "kind": "weekly", "group": "weekly", "percent": 76, "resets_at": "2026-01-12T00:00:00.573208+00:00", "is_active": true },
    {
      "kind": "weekly_scoped",
      "group": "weekly",
      "percent": 12,
      "resets_at": "2026-01-12T00:00:00.573673+00:00",
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

  @Test func emptyPayloadFailsAndFallsBack() async throws {
    // A 200 with no recognizable windows must fail so the pipeline can fall
    // through to the mock instead of rendering an empty card.
    let live = CodexUsageStrategy(
      transport: StubTransport(json: #"{"plan":"free"}"#),
      loadCredentials: { CodexCredentials(accessToken: "tok", accountID: nil) }
    )
    let context = ProviderFetchContext(provider: .codex, now: Date())
    do {
      _ = try await live.fetch(context)
      Issue.record("expected emptyUsage error")
    } catch {
      #expect(live.shouldFallback(on: error) == true)
    }

    let pipeline = ProviderFetchPipeline { _ in [live, MockProviders.codexStrategy] }
    let result = try await pipeline.fetch(context).get()
    #expect(result.sourceLabel == "Mock")
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
      loadCredentials: {
        ClaudeCredentials(
          accessToken: "tok",
          subscriptionType: "max",
          rateLimitTier: "default_claude_max_20x"
        )
      }
    )
    let result = try await strategy.fetch(ProviderFetchContext(provider: .claude, now: Date()))

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
    #expect(fable.resetsAt != nil)
    #expect(fable.duration == TimeInterval(7 * 24 * 3600))
  }

  @Test func unavailableWithoutCredentials() async {
    let strategy = ClaudeUsageStrategy(
      transport: StubTransport(json: "{}"),
      loadCredentials: { throw ClaudeCredentialsError.notFound }
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
  @Test func pipelineFallsThroughUnavailableLiveStrategyToMock() async throws {
    // A live strategy that reports unavailable (no credentials) must fall
    // through to the mock, so the app is never empty during development.
    let unavailableLive = CodexUsageStrategy(
      transport: StubTransport(json: "{}"),
      loadCredentials: { throw CodexCredentialsError.notFound }
    )
    let pipeline = ProviderFetchPipeline { _ in [unavailableLive, MockProviders.codexStrategy] }
    let result = try await pipeline.fetch(ProviderFetchContext(provider: .codex, now: Date())).get()

    #expect(result.sourceLabel == "Mock")
    #expect(result.usage.plan == "Pro 5x")
  }

  @Test func everyProviderStillHasADescriptor() {
    #expect(ProviderRegistry.isComplete)
  }
}
