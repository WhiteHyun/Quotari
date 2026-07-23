import CustomDump
import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageInsightsEstimatorTests {
  @Test func exactAccountProducesScopeSafeCachedInsights() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: "Test",
      credentialSource: .codexAuthFile(path: fixture.codexHome.appendingPathComponent("auth.json").path),
      credentialIdentity: "account"
    )
    let estimator = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )

    let summary = try #require(await estimator.insights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ))
    let period = try #require(summary.period(.thirtyDays))

    expectNoDifference(summary.accountScope, .exact)
    expectNoDifference(summary.source, .localCodexLogs)
    #expect(!summary.scopeKey.accountScopeID.contains(fixture.root.path))
    expectNoDifference(period.tokens.total, .available(170))
    expectNoDifference(period.sessionCount, .available(1))
    expectNoDifference(
      estimator.cachedInsights(
        provider: .codex,
        account: account,
        now: fixture.now,
        historyDays: 30
      ),
      summary
    )
    expectNoDifference(summary.costSummary?.monthTokens, 170)

    estimator.invalidateInsights(provider: .codex, account: account, historyDays: 30)
    #expect(estimator.cachedInsights(
      provider: .codex,
      account: account,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }

  @Test func capturedAccountsDoNotInheritTheLiveScope() async throws {
    let fixture = try InsightsEstimatorFixture()
    defer { fixture.cleanup() }
    let estimator = LocalUsageCostEstimator.testing(
      environment: ["CODEX_HOME": fixture.codexHome.path],
      homeDirectory: fixture.root,
      cacheDirectory: fixture.cache
    )
    let captured = ProviderAccount(
      provider: .codex,
      displayName: "Saved",
      detail: nil,
      credentialSource: .quotariRegistry(id: "saved")
    )

    #expect(await estimator.insights(
      provider: .codex,
      account: captured,
      now: fixture.now,
      historyDays: 30
    ) == nil)
  }
}

private struct InsightsEstimatorFixture {
  let root: URL
  let codexHome: URL
  let cache: URL
  let now: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-insights-estimator-\(UUID().uuidString)", isDirectory: true)
    codexHome = root.appendingPathComponent("codex", isDirectory: true)
    cache = root.appendingPathComponent("cache", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))

    let line: [String: Any] = [
      "type": "event_msg",
      "timestamp": "2026-07-08T09:00:00Z",
      "payload": [
        "type": "token_count",
        "info": [
          "model": "gpt-5",
          "total_token_usage": [
            "input_tokens": 150,
            "cached_input_tokens": 50,
            "output_tokens": 20,
          ],
        ],
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
    try data.write(to: sessions.appendingPathComponent("usage.jsonl"))
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
