import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageCostEstimatorReviewTests {
  @Test func codexTotalsAdvanceBeforeTheHistoryWindow() async throws {
    let env = try ReviewCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        Self.codexTotalLine(timestamp: "2026-06-01T09:00:00Z", input: 1000, cached: 100, output: 100),
        Self.codexTotalLine(timestamp: "2026-07-08T09:00:00Z", input: 1200, cached: 120, output: 150),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 250)
    #expect(summary.latestTokens == 250)
  }

  @Test func codexTotalsWinOverRepeatedLastUsageSnapshots() async throws {
    let env = try ReviewCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        Self.codexTotalLine(
          timestamp: "2026-07-08T09:00:00Z",
          input: 100,
          cached: 10,
          output: 20,
          lastInput: 100,
          lastCached: 10,
          lastOutput: 20
        ),
        Self.codexTotalLine(
          timestamp: "2026-07-08T09:01:00Z",
          input: 100,
          cached: 10,
          output: 20,
          lastInput: 100,
          lastCached: 10,
          lastOutput: 20
        ),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 120)
    #expect(summary.latestTokens == 120)
  }

  @Test func codexReasoningOutputTokensAreCountedAsOutput() async throws {
    let env = try ReviewCostTestEnvironment()
    defer { env.cleanup() }

    let codexHome = env.root.appendingPathComponent("codex", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try env.createDirectory(sessions)
    try env.writeJSONL(
      sessions.appendingPathComponent("usage.jsonl"),
      [
        Self.codexTotalLine(
          timestamp: "2026-07-08T09:00:00Z",
          input: 100,
          cached: 10,
          output: 20,
          reasoningOutput: 30
        ),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .codex, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 150)
    #expect(summary.latestTokens == 150)
    #expect(summary.todaySpend > 0.00061 && summary.todaySpend < 0.00062)
  }

  @Test func claudeStreamingAssistantUsageIsDeduplicatedByRequest() async throws {
    let env = try ReviewCostTestEnvironment()
    defer { env.cleanup() }

    let claudeConfig = env.root.appendingPathComponent("claude-config", isDirectory: true)
    let project = claudeConfig
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("quotari", isDirectory: true)
    try env.createDirectory(project)
    try env.writeJSONL(
      project.appendingPathComponent("usage.jsonl"),
      [
        Self.claudeAssistantLine(
          timestamp: "2026-07-08T10:00:00Z",
          requestID: "req-1",
          input: 100,
          output: 20
        ),
        Self.claudeAssistantLine(
          timestamp: "2026-07-08T10:00:01Z",
          requestID: "req-1",
          input: 150,
          output: 30
        ),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .claude, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 180)
    #expect(summary.latestTokens == 180)
  }

  @Test func claudeCurrentVersionedModelRatesOverrideLegacyFamilies() {
    let pricing = LocalModelPricing()
    let tokens = TokenTotals(input: 1_000_000, cacheRead: 0, cacheWrite: 0, output: 1_000_000)

    #expect(abs(pricing.costUSD(provider: .claude, model: "claude-opus-4-5", tokens: tokens) - 30) < 0.0001)
    #expect(abs(pricing.costUSD(provider: .claude, model: "claude_opus_4_8", tokens: tokens) - 30) < 0.0001)
    #expect(abs(pricing.costUSD(provider: .claude, model: "claude-haiku-4-5", tokens: tokens) - 6) < 0.0001)
    #expect(abs(pricing.costUSD(provider: .claude, model: "claude-opus-4-1", tokens: tokens) - 90) < 0.0001)
  }

  @Test func cachedCostSummaryRejectsPreviousDayWindows() throws {
    let env = try ReviewCostTestEnvironment()
    defer { env.cleanup() }

    let cache = LocalUsageCostCache(
      cacheDirectory: env.root.appendingPathComponent("cost-cache", isDirectory: true)
    )
    let summary = CostSummary(
      todaySpend: 1,
      monthSpend: 1,
      monthTokens: 100,
      latestTokens: 100,
      sourceDescription: "Estimated from local logs",
      daily: Self.dailySeries(endingAt: env.today, count: 30)
    )
    cache.save(summary, provider: .codex, now: env.now, historyDays: 30)

    #expect(cache.load(provider: .codex, now: env.now, historyDays: 30) == summary)
    #expect(cache.load(provider: .codex, now: env.now.addingTimeInterval(86400), historyDays: 30) == nil)
  }

  private static func codexTotalLine(
    timestamp: String,
    input: Int,
    cached: Int,
    output: Int,
    reasoningOutput: Int = 0,
    lastInput: Int? = nil,
    lastCached: Int? = nil,
    lastOutput: Int? = nil,
    lastReasoningOutput: Int = 0
  ) -> [String: Any] {
    var info: [String: Any] = [
      "model": "gpt-5",
      "total_token_usage": tokenUsage(
        input: input,
        cached: cached,
        output: output,
        reasoningOutput: reasoningOutput
      ),
    ]
    if let lastInput, let lastCached, let lastOutput {
      info["last_token_usage"] = tokenUsage(
        input: lastInput,
        cached: lastCached,
        output: lastOutput,
        reasoningOutput: lastReasoningOutput
      )
    }
    return [
      "type": "event_msg",
      "timestamp": timestamp,
      "payload": [
        "type": "token_count",
        "info": info,
      ],
    ]
  }

  private static func tokenUsage(input: Int, cached: Int, output: Int, reasoningOutput: Int = 0) -> [String: Any] {
    var usage: [String: Any] = [
      "input_tokens": input,
      "cached_input_tokens": cached,
      "output_tokens": output,
    ]
    if reasoningOutput > 0 {
      usage["reasoning_output_tokens"] = reasoningOutput
    }
    return usage
  }

  private static func claudeAssistantLine(
    timestamp: String,
    requestID: String? = nil,
    messageID: String? = nil,
    model: String = "claude-sonnet-4",
    input: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    output: Int
  ) -> [String: Any] {
    var message: [String: Any] = [
      "model": model,
      "usage": [
        "input_tokens": input,
        "cache_read_input_tokens": cacheRead,
        "cache_creation_input_tokens": cacheWrite,
        "output_tokens": output,
      ],
    ]
    if let messageID {
      message["id"] = messageID
    }
    var object: [String: Any] = [
      "type": "assistant",
      "timestamp": timestamp,
      "message": message,
    ]
    if let requestID {
      object["requestId"] = requestID
    }
    return object
  }

  private static func dailySeries(endingAt end: Date, count: Int) -> [DailyCost] {
    (0 ..< count).compactMap { index in
      Calendar(identifier: .gregorian).date(byAdding: .day, value: index - (count - 1), to: end)
    }
    .map { DailyCost(date: $0, spend: 1, tokens: 100) }
  }
}

private struct ReviewCostTestEnvironment {
  let root: URL
  let now: Date
  let today: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-review-cost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
    today = Calendar(identifier: .gregorian).startOfDay(for: now)
  }

  func createDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func writeJSONL(_ url: URL, _ objects: [[String: Any]]) throws {
    let lines = try objects.map { object in
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      return try #require(String(data: data, encoding: .utf8))
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
