import Foundation
@testable import QuotariCore
import Testing

struct DynamicPricingEstimatorIntegrationTests {
  @Test func estimatorUsesInjectedRemoteModelPricing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-dynamic-estimator-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Self.writeSession(root: root)
    let catalog = try Self.catalog()
    let estimator = LocalUsageCostEstimator(
      environment: ["CODEX_HOME": root.appendingPathComponent("codex").path],
      homeDirectory: root,
      pricingCatalogProvider: FixedPricingCatalogProvider(value: .init(
        remote: catalog,
        remoteIsStale: false
      ))
    )
    let now = try #require(LenientDateParser.parse("2026-01-07T12:00:00Z"))
    let summary = try #require(await estimator.costSummary(provider: .codex, now: now, historyDays: 1))

    #expect(abs(summary.monthSpend - 18) < 0.0001)
    #expect(summary.topModel == "future-gpt")
    #expect(summary.estimateCoverage?.isComplete == true)
  }

  private static func writeSession(root: URL) throws {
    let sessions = root.appendingPathComponent("codex/sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let lines: [[String: Any]] = [
      ["type": "turn_context", "payload": ["model": "future-gpt"]],
      [
        "type": "event_msg",
        "timestamp": "2026-01-07T09:00:00Z",
        "payload": [
          "type": "token_count",
          "info": [
            "total_token_usage": [
              "input_tokens": 1_000_000,
              "cached_input_tokens": 0,
              "output_tokens": 1_000_000,
            ],
          ],
        ],
      ],
    ]
    let data = try lines.map { object in
      let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      return try #require(String(data: encoded, encoding: .utf8))
    }
    .joined(separator: "\n")
    .data(using: .utf8)
    try #require(data).write(to: sessions.appendingPathComponent("usage.jsonl"))
  }

  private static func catalog() throws -> ModelPricingCatalog {
    let data = Data("""
    {
      "future-gpt": {
        "litellm_provider": "openai",
        "input_cost_per_token": 0.000007,
        "output_cost_per_token": 0.000011
      }
    }
    """.utf8)
    return try LiteLLMPricingCatalogParser.parse(data).catalog
  }
}

private struct FixedPricingCatalogProvider: ModelPricingCatalogProviding {
  let value: ModelPricingCatalogSnapshot

  func snapshot(for keys: Set<ModelPricingKey>, now: Date) async -> ModelPricingCatalogSnapshot {
    value
  }
}
