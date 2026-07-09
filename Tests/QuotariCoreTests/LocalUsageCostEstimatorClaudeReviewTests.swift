import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageCostEstimatorClaudeReviewTests {
  @Test func claudeStreamingAssistantUsageIsDeduplicatedByRequest() async throws {
    let env = try ClaudeReviewCostTestEnvironment()
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
          cacheRead: 50,
          cacheWrite: 5,
          output: 20
        ),
        Self.claudeAssistantLine(
          timestamp: "2026-07-08T10:00:01Z",
          requestID: "req-1",
          input: 150,
          cacheRead: 120,
          cacheWrite: 12,
          output: 30
        ),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path],
      homeDirectory: env.root
    )
    let summary = try #require(await estimator.costSummary(provider: .claude, now: env.now, historyDays: 30))

    #expect(summary.monthTokens == 132)
    #expect(summary.latestTokens == 132)
  }

  @Test func claudeStreamingAssistantUsageIgnoresPlaceholderInputOutput() async throws {
    let env = try ClaudeReviewCostTestEnvironment()
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
          input: 100_000,
          output: 10000
        ),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path],
      homeDirectory: env.root
    )

    #expect(await estimator.costSummary(provider: .claude, now: env.now, historyDays: 30) == nil)
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
}

private struct ClaudeReviewCostTestEnvironment {
  let root: URL
  let now: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-claude-review-cost-\(UUID().uuidString)", isDirectory: true)
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
