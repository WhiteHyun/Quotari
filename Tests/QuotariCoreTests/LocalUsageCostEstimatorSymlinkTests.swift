import Foundation
@testable import QuotariCore
import Testing

struct LocalUsageCostEstimatorSymlinkTests {
  @Test func claudeProjectRootsResolveSymlinksBeforeDeduping() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-symlink-cost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
    let claudeConfig = root.appendingPathComponent("claude-config", isDirectory: true)
    let symlinkConfig = root.appendingPathComponent("claude-config-link", isDirectory: true)
    let project = claudeConfig
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("quotari", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: symlinkConfig, withDestinationURL: claudeConfig)
    try Self.writeJSONL(
      project.appendingPathComponent("usage.jsonl"),
      [
        Self.claudeAssistantLine(
          timestamp: "2026-07-08T10:00:00Z",
          input: 100,
          cacheRead: 100,
          cacheWrite: 20,
          output: 20
        ),
      ]
    )

    let estimator = LocalUsageCostEstimator(
      environment: ["CLAUDE_CONFIG_DIR": "\(claudeConfig.path),\(symlinkConfig.path)"],
      homeDirectory: root
    )
    let summary = try #require(await estimator.costSummary(provider: .claude, now: now, historyDays: 30))

    #expect(summary.monthTokens == 120)
    #expect(summary.latestTokens == 120)
  }

  private static func claudeAssistantLine(
    timestamp: String,
    input: Int,
    cacheRead: Int,
    cacheWrite: Int,
    output: Int
  ) -> [String: Any] {
    [
      "type": "assistant",
      "timestamp": timestamp,
      "message": [
        "model": "claude-sonnet-4",
        "usage": [
          "input_tokens": input,
          "cache_read_input_tokens": cacheRead,
          "cache_creation_input_tokens": cacheWrite,
          "output_tokens": output,
        ],
      ],
    ]
  }

  private static func writeJSONL(_ url: URL, _ objects: [[String: Any]]) throws {
    let lines = try objects.map { object in
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      return try #require(String(data: data, encoding: .utf8))
    }
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }
}
