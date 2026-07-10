import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageCostEstimatorTests {}

extension LocalUsageCostEstimatorTests {
  @Test func codexLogsProduceCostSummary() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        [
          "type": "event_msg",
          "timestamp": "2026-07-08T09:00:00Z",
          "payload": [
            "type": "token_count",
            "info": [
              "model": "gpt-5",
              "last_token_usage": [
                "input_tokens": 1_000_000,
                "cached_input_tokens": 500_000,
                "output_tokens": 200_000,
              ],
            ],
          ],
        ],
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.daily.count == 30)
    #expect(summary.todaySpend > 2.68 && summary.todaySpend < 2.69)
    #expect(summary.monthSpend == summary.todaySpend)
    #expect(summary.monthTokens == 1_200_000)
    #expect(summary.latestTokens == 1_200_000)
    #expect(summary.topModel == "gpt-5")
    #expect(summary.sourceDescription == "Estimated from local Codex logs")
  }

  @Test func codexTotalSnapshotsUseDeltas() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        Self.codexTotalLine(timestamp: "2026-07-08T09:00:00Z", input: 100, cached: 10, output: 20),
        Self.codexTotalLine(timestamp: "2026-07-08T09:01:00Z", input: 150, cached: 15, output: 35),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 185)
    #expect(summary.latestTokens == 185)
  }

  @Test func codexTurnContextSuppliesModelForTokenCounts() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        [
          "type": "turn_context",
          "timestamp": "2026-07-08T09:00:00Z",
          "payload": [
            "model": "gpt-5.5",
          ],
        ],
        Self.codexTotalLineWithoutModel(timestamp: "2026-07-08T09:01:00Z", input: 150, cached: 15, output: 35),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 185)
    #expect(summary.topModel == "gpt-5.5")
  }

  @Test func costSummaryIsCachedAfterScan() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    let cache = env.root.appendingPathComponent("cost-cache", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        Self.codexTotalLine(timestamp: "2026-07-08T09:00:00Z", input: 150, cached: 15, output: 35),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root,
      cacheDirectory: cache
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    let cached = estimator.cachedCostSummary(provider: .codex, now: env.now, historyDays: 30)
    #expect(cached == summary)
  }

  @Test func selectedCodexAccountScopesLogsAndCacheToCredentialSource() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let defaultHome = env.root.appendingPathComponent(".codex", isDirectory: true)
    let customHome = env.root.appendingPathComponent("custom-codex", isDirectory: true)
    let defaultSessions = defaultHome.appendingPathComponent("sessions", isDirectory: true)
    let customSessions = customHome.appendingPathComponent("sessions", isDirectory: true)
    let cache = env.root.appendingPathComponent("cost-cache", isDirectory: true)
    try env.createDirectory(defaultSessions)
    try env.createDirectory(customSessions)
    try env.writeJSONL(
      defaultSessions.appendingPathComponent("usage.jsonl"),
      [Self.codexTotalLine(timestamp: "2026-07-08T09:00:00Z", input: 100, cached: 0, output: 0)]
    )
    try env.writeJSONL(
      customSessions.appendingPathComponent("usage.jsonl"),
      [Self.codexTotalLine(timestamp: "2026-07-08T09:00:00Z", input: 1000, cached: 0, output: 0)]
    )
    let defaultAccount = ProviderAccount(
      provider: .codex,
      displayName: "Default",
      detail: "Default",
      credentialSource: .codexAuthFile(path: defaultHome.appendingPathComponent("auth.json").path)
    )
    let customAccount = ProviderAccount(
      provider: .codex,
      displayName: "Custom",
      detail: "CODEX_HOME",
      credentialSource: .codexAuthFile(path: customHome.appendingPathComponent("auth.json").path)
    )
    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": customHome.path],
      homeDirectory: env.root,
      cacheDirectory: cache
    )

    let defaultSummary = try await Self.scopedSummary(
      using: estimator,
      account: defaultAccount,
      now: env.now
    )
    let customSummary = try await Self.scopedSummary(
      using: estimator,
      account: customAccount,
      now: env.now
    )

    #expect(defaultSummary.monthTokens == 100)
    #expect(customSummary.monthTokens == 1000)
    #expect(defaultSummary.sourceDescription == "Estimated from selected account's local Codex logs")
  }

  @Test func codexUnknownModelDoesNotExposeProviderNameAsTopModel() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        Self.codexTotalLineWithoutModel(timestamp: "2026-07-08T09:00:00Z", input: 150, cached: 15, output: 35),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 185)
    #expect(summary.topModel == nil)
  }
}

extension LocalUsageCostEstimatorTests {
  @Test func claudeLogsProduceCostSummary() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let claudeConfig = env.root.appendingPathComponent("claude-config", isDirectory: true)
    let project = claudeConfig
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("quotari", isDirectory: true)
    try env.createDirectory(project)
    try env.writeJSONL(
      project.appendingPathComponent("usage.jsonl"),
      [
        [
          "type": "assistant",
          "timestamp": "2026-07-08T10:00:00Z",
          "message": [
            "model": "claude-sonnet-4",
            "usage": [
              "input_tokens": 100_000,
              "cache_read_input_tokens": 50000,
              "cache_creation_input_tokens": 25000,
              "output_tokens": 10000,
            ],
          ],
        ],
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .claude, now: env.now, historyDays: 30))

    #expect(summary.daily.count == 30)
    #expect(abs(summary.todaySpend - 0.10875) < 0.0001)
    #expect(summary.monthTokens == 75000)
    #expect(summary.latestTokens == 75000)
    #expect(summary.topModel == "claude-sonnet-4")
    #expect(summary.sourceDescription == "Estimated from local Claude cache logs")
  }

  @Test func claudeDesktopPlaceholderUsageWithoutCacheIsIgnored() async throws {
    let env = try LocalCostTestEnvironment()
    defer { env.cleanup() }

    let project = env.root
      .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
      .appendingPathComponent("workspace-id/session-id/local_agent/.claude/projects/quotari", isDirectory: true)
    try env.createDirectory(project)
    try env.writeJSONL(
      project.appendingPathComponent("usage.jsonl"),
      [
        [
          "type": "assistant",
          "timestamp": "2026-07-08T10:00:00Z",
          "message": [
            "model": "claude-sonnet-4",
            "usage": [
              "input_tokens": 1000,
              "output_tokens": 250,
            ],
          ],
        ],
      ]
    )

    let estimator = LocalUsageCostEstimator(environment: [:], homeDirectory: env.root)
    #expect(await estimator.costSummary(provider: .claude, now: env.now, historyDays: 30) == nil)
  }

  private static func scopedSummary(
    using estimator: LocalUsageCostEstimator,
    account: ProviderAccount,
    now: Date
  ) async throws -> CostSummary {
    let summary = try #require(await estimator.costSummary(
      provider: .codex,
      account: account,
      now: now,
      historyDays: 30
    ))
    #expect(estimator.cachedCostSummary(
      provider: .codex,
      account: account,
      now: now,
      historyDays: 30
    ) == summary)
    return summary
  }

  private static func codexTotalLine(timestamp: String, input: Int, cached: Int, output: Int) -> [String: Any] {
    [
      "type": "event_msg",
      "timestamp": timestamp,
      "payload": [
        "type": "token_count",
        "info": [
          "model": "gpt-5",
          "total_token_usage": [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
          ],
        ],
      ],
    ]
  }

  private static func codexTotalLineWithoutModel(
    timestamp: String,
    input: Int,
    cached: Int,
    output: Int
  ) -> [String: Any] {
    [
      "type": "event_msg",
      "timestamp": timestamp,
      "payload": [
        "type": "token_count",
        "info": [
          "total_token_usage": [
            "input_tokens": input,
            "cached_input_tokens": cached,
            "output_tokens": output,
          ],
        ],
      ],
    ]
  }
}

private struct LocalCostTestEnvironment {
  let root: URL
  let now: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-cost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
  }

  func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func writeJSONL(_ url: URL, _ objects: [[String: Any]]) throws {
    let data = try objects.map { object in
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      return try #require(String(data: data, encoding: .utf8))
    }
    .joined(separator: "\n")
    .data(using: .utf8)
    try #require(data).write(to: url)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
