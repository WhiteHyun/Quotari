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

  private static func codexTotalLine(
    timestamp: String,
    input: Int,
    cached: Int,
    output: Int,
    lastInput: Int? = nil,
    lastCached: Int? = nil,
    lastOutput: Int? = nil
  ) -> [String: Any] {
    var info: [String: Any] = [
      "model": "gpt-5",
      "total_token_usage": tokenUsage(input: input, cached: cached, output: output),
    ]
    if let lastInput, let lastCached, let lastOutput {
      info["last_token_usage"] = tokenUsage(input: lastInput, cached: lastCached, output: lastOutput)
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

  private static func tokenUsage(input: Int, cached: Int, output: Int) -> [String: Any] {
    [
      "input_tokens": input,
      "cached_input_tokens": cached,
      "output_tokens": output,
    ]
  }
}

private struct ReviewCostTestEnvironment {
  let root: URL
  let now: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-review-cost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
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
