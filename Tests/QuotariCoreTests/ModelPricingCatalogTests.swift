import Foundation
@testable import QuotariCore
import Testing

struct ModelPricingCatalogParserTests {
  @Test func parsesOpenAIAndAnthropicPricingLossily() throws {
    let parsed = try LiteLLMPricingCatalogParser.parse(Data(Self.catalogJSON.utf8))

    let sol = try #require(parsed.catalog.pricing(for: .init(provider: .codex, modelID: "gpt-5.6-sol")))
    #expect(sol.standard.inputPerMillion == 5)
    #expect(sol.standard.cacheReadPerMillion == 0.5)
    #expect(sol.standard.cacheWritePerMillion == 6.25)
    #expect(sol.standard.outputPerMillion == 30)
    #expect(sol.longContext?.thresholdTokens == 272_000)
    #expect(sol.longContext?.overrides.outputPerMillion == 45)

    let opus = try #require(parsed.catalog.pricing(for: .init(provider: .claude, modelID: "claude-opus-4-8")))
    #expect(opus.standard.inputPerMillion == 5)
    #expect(opus.longContext?.thresholdTokens == 200_000)
    #expect(opus.longContext?.overrides.cacheReadPerMillion == 1)

    #expect(parsed.catalog.pricing(for: .init(provider: .codex, modelID: "broken-model")) == nil)
    #expect(parsed.issues.contains { $0.modelID == "broken-model" })
  }

  @Test func normalizedIdentifierCollisionsAreExcluded() throws {
    let data = Data("""
    {
      "future_model": {
        "litellm_provider": "openai",
        "input_cost_per_token": 0.000001,
        "output_cost_per_token": 0.000002
      },
      "future-model": {
        "litellm_provider": "openai",
        "input_cost_per_token": 0.000003,
        "output_cost_per_token": 0.000004
      }
    }
    """.utf8)

    let parsed = try LiteLLMPricingCatalogParser.parse(data)
    #expect(parsed.catalog.pricing(for: .init(provider: .codex, modelID: "future-model")) == nil)
    #expect(parsed.issues.contains { $0.reason.contains("collision") })
  }

  @Test func parsesAndSelectsDynamicLongContextTiers() throws {
    let data = Data("""
    {
      "future-gpt": {
        "litellm_provider": "openai",
        "input_cost_per_token": 0.000001,
        "output_cost_per_token": 0.000002,
        "input_cost_per_token_above_128k_tokens": 0.000003,
        "output_cost_per_token_above_128k_tokens": 0.000004,
        "input_cost_per_token_above_512k_tokens": 0.000005,
        "output_cost_per_token_above_512k_tokens": 0.000006
      }
    }
    """.utf8)

    let catalog = try LiteLLMPricingCatalogParser.parse(data).catalog
    let pricing = try #require(catalog.pricing(for: .init(provider: .codex, modelID: "future-gpt")))

    #expect(pricing.longContexts.map(\.thresholdTokens) == [128_000, 512_000])
    #expect(pricing.rates(contextInputTokens: 128_000).inputPerMillion == 1)
    #expect(pricing.rates(contextInputTokens: 128_001).inputPerMillion == 3)
    #expect(pricing.rates(contextInputTokens: 512_001).inputPerMillion == 5)
    #expect(pricing.rates(contextInputTokens: 512_001).outputPerMillion == 6)
  }

  @Test func longContextPricingAndPartialCoverageAreApplied() throws {
    let parsed = try LiteLLMPricingCatalogParser.parse(Data(Self.catalogJSON.utf8))
    let pricing = LocalModelPricing(snapshot: ModelPricingCatalogSnapshot(
      remote: parsed.catalog,
      remoteIsStale: true
    ))
    let calendar = Calendar(identifier: .gregorian)
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_767_744_000))
    let range = DayRange(start: day, end: day, calendar: calendar)
    let summary = try #require(LocalCostSummaryBuilder.summary(
      provider: .codex,
      records: [
        LocalTokenRecord(
          day: day,
          model: "gpt-5.6-sol",
          tokens: TokenTotals(input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0, output: 1_000_000),
          contextInputTokens: 300_000
        ),
        LocalTokenRecord(
          day: day,
          model: "future-gpt",
          tokens: TokenTotals(input: 100, cacheRead: 0, cacheWrite: 0, output: 0)
        ),
      ],
      range: range,
      pricing: pricing
    ))

    #expect(abs(summary.monthSpend - 56) < 0.0001)
    #expect(summary.monthTokens == 3_000_100)
    #expect(summary.estimateCoverage?.pricedTokens == 3_000_000)
    #expect(summary.estimateCoverage?.unpricedTokens == 100)
    #expect(summary.estimateCoverage?.unpricedModels == ["future-gpt"])
    #expect(summary.estimateCoverage?.usesStalePricing == true)
    #expect(summary.estimateCoverage?.isComplete == false)
  }

  @Test func missingRemoteCacheRatesUseBundledModelComponents() throws {
    let data = Data("""
    {
      "gpt-5.5": {
        "litellm_provider": "openai",
        "input_cost_per_token": 0.000007,
        "output_cost_per_token": 0.000011
      }
    }
    """.utf8)
    let catalog = try LiteLLMPricingCatalogParser.parse(data).catalog
    let pricing = LocalModelPricing(snapshot: .init(remote: catalog, remoteIsStale: false))
    let result = pricing.price(
      provider: .codex,
      model: "gpt-5.5",
      tokens: TokenTotals(input: 1_000_000, cacheRead: 1_000_000, cacheWrite: 0, output: 1_000_000),
      contextInputTokens: 10000
    )

    #expect(abs(result.spend - 18.5) < 0.0001)
    #expect(result.unpricedTokens == 0)
  }

  @Test func legacyCostSummaryCacheDecodesWithoutCoverage() throws {
    let legacy = LegacyCostSummary(
      currencyCode: "USD",
      todaySpend: 1,
      monthSpend: 2,
      monthTokens: 3,
      latestTokens: 4,
      topModel: "gpt-5.5",
      todaySpendLabel: "Today",
      monthSpendLabel: "30d cost",
      sourceDescription: "Estimated from local logs",
      daily: []
    )
    let decoded = try JSONDecoder().decode(CostSummary.self, from: JSONEncoder().encode(legacy))

    #expect(decoded.estimateCoverage == nil)
  }

  static let catalogJSON = """
  {
    "gpt-5.6-sol": {
      "litellm_provider": "openai",
      "input_cost_per_token": 0.000005,
      "cache_read_input_token_cost": 0.0000005,
      "cache_creation_input_token_cost": 0.00000625,
      "output_cost_per_token": 0.00003,
      "input_cost_per_token_above_272k_tokens": 0.00001,
      "cache_read_input_token_cost_above_272k_tokens": 0.000001,
      "cache_creation_input_token_cost_above_272k_tokens": 0.0000125,
      "output_cost_per_token_above_272k_tokens": 0.000045,
      "unknown_future_field": true
    },
    "claude-opus-4-8": {
      "litellm_provider": "anthropic",
      "input_cost_per_token": 0.000005,
      "cache_read_input_token_cost": 0.0000005,
      "cache_creation_input_token_cost": 0.00000625,
      "output_cost_per_token": 0.000025,
      "input_cost_per_token_above_200k_tokens": 0.00001,
      "cache_read_input_token_cost_above_200k_tokens": 0.000001,
      "cache_creation_input_token_cost_above_200k_tokens": 0.0000125,
      "output_cost_per_token_above_200k_tokens": 0.0000375
    },
    "broken-model": {
      "litellm_provider": "openai",
      "input_cost_per_token": "invalid",
      "output_cost_per_token": 0.000001
    },
    "ignored-model": {
      "litellm_provider": "google",
      "input_cost_per_token": 0.000001,
      "output_cost_per_token": 0.000001
    }
  }
  """

  private struct LegacyCostSummary: Encodable {
    let currencyCode: String
    let todaySpend: Double
    let monthSpend: Double
    let monthTokens: Int
    let latestTokens: Int
    let topModel: String?
    let todaySpendLabel: String
    let monthSpendLabel: String
    let sourceDescription: String
    let daily: [DailyCost]
  }
}

struct RemoteModelPricingCatalogStoreTests {
  @Test func usesETagAndRefreshesTimestampOnNotModified() async throws {
    let cacheDirectory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = PricingCatalogTransport(responses: [
      .success(.init(
        data: Data(ModelPricingCatalogParserTests.catalogJSON.utf8),
        status: 200,
        headers: ["ETag": "catalog-v1"]
      )),
      .success(.init(data: Data(), status: 304, headers: ["ETag": "catalog-v1"])),
    ])
    let store = try RemoteModelPricingCatalogStore(
      transport: transport,
      sourceURL: #require(URL(string: "https://example.com/pricing.json")),
      cacheDirectory: cacheDirectory,
      refreshInterval: 1,
      retryInterval: 0
    )
    let now = Date(timeIntervalSince1970: 1_767_744_000)
    let key = ModelPricingKey(provider: .codex, modelID: "gpt-5.6-sol")

    let first = await store.snapshot(for: [key], now: now)
    let second = await store.snapshot(for: [key], now: now.addingTimeInterval(2))

    #expect(first.remote.pricing(for: key) != nil)
    #expect(second.remoteIsStale == false)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(requests[0].authorization == nil)
    #expect(requests[1].ifNoneMatch == "catalog-v1")
  }

  @Test func loadsLastKnownGoodCacheWhenRefreshFails() async {
    let cacheDirectory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let now = Date(timeIntervalSince1970: 1_767_744_000)
    let key = ModelPricingKey(provider: .claude, modelID: "claude-opus-4-8")
    let successfulTransport = PricingCatalogTransport(responses: [
      .success(.init(
        data: Data(ModelPricingCatalogParserTests.catalogJSON.utf8),
        status: 200,
        headers: ["ETag": "catalog-v1"]
      )),
    ])
    let writer = RemoteModelPricingCatalogStore(
      transport: successfulTransport,
      cacheDirectory: cacheDirectory,
      refreshInterval: 1,
      retryInterval: 0
    )
    _ = await writer.snapshot(for: [key], now: now)

    let failingTransport = PricingCatalogTransport(responses: [.failure(.offline)])
    let reader = RemoteModelPricingCatalogStore(
      transport: failingTransport,
      cacheDirectory: cacheDirectory,
      refreshInterval: 1,
      retryInterval: 0
    )
    let stale = await reader.snapshot(for: [key], now: now.addingTimeInterval(2))

    #expect(stale.remote.pricing(for: key) != nil)
    #expect(stale.remoteIsStale == true)
  }

  @Test func invalidRefreshDoesNotReplaceLastKnownGoodCatalog() async {
    let cacheDirectory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = PricingCatalogTransport(responses: [
      .success(.init(
        data: Data(ModelPricingCatalogParserTests.catalogJSON.utf8),
        status: 200,
        headers: ["ETag": "catalog-v1"]
      )),
      .success(.init(data: Data(#"{"broken":true}"#.utf8), status: 200, headers: [:])),
    ])
    let store = RemoteModelPricingCatalogStore(
      transport: transport,
      cacheDirectory: cacheDirectory,
      refreshInterval: 1,
      retryInterval: 0
    )
    let now = Date(timeIntervalSince1970: 1_767_744_000)
    let key = ModelPricingKey(provider: .codex, modelID: "gpt-5.6-sol")

    _ = await store.snapshot(for: [key], now: now)
    let afterInvalidRefresh = await store.snapshot(for: [key], now: now.addingTimeInterval(2))

    #expect(afterInvalidRefresh.remote.pricing(for: key) != nil)
    #expect(afterInvalidRefresh.remoteIsStale == true)
  }

  @Test func throttlesRepeatedUnknownModelFailures() async {
    let cacheDirectory = Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = PricingCatalogTransport(responses: [.failure(.offline), .failure(.offline)])
    let store = RemoteModelPricingCatalogStore(
      transport: transport,
      cacheDirectory: cacheDirectory,
      retryInterval: 3600
    )
    let now = Date(timeIntervalSince1970: 1_767_744_000)
    let key = ModelPricingKey(provider: .codex, modelID: "future-gpt")

    _ = await store.snapshot(for: [key], now: now)
    _ = await store.snapshot(for: [key], now: now.addingTimeInterval(1800))

    #expect(await transport.recordedRequests().count == 1)
  }

  private static func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-pricing-\(UUID().uuidString)", isDirectory: true)
  }
}

private actor PricingCatalogTransport: ProviderHTTPTransport {
  struct StubResponse: Sendable {
    let data: Data
    let status: Int
    let headers: [String: String]
  }

  struct RequestRecord: Sendable {
    let authorization: String?
    let ifNoneMatch: String?
  }

  enum StubError: Error, Sendable {
    case offline
  }

  private var responses: [Result<StubResponse, StubError>]
  private var requests: [RequestRecord] = []

  init(responses: [Result<StubResponse, StubError>]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(RequestRecord(
      authorization: request.value(forHTTPHeaderField: "Authorization"),
      ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")
    ))
    guard !responses.isEmpty else { throw StubError.offline }
    let stub = try responses.removeFirst().get()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.status,
      httpVersion: nil,
      headerFields: stub.headers
    )!
    return (stub.data, response)
  }

  func recordedRequests() -> [RequestRecord] {
    requests
  }
}
