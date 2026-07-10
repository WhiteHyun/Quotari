import Foundation
@testable import QuotariCore
import Testing

struct PricingCatalogConcurrencyTests {
  @Test func concurrentColdCacheSnapshotsAwaitOneRefresh() async {
    let cacheDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-pricing-concurrency-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let transport = SuspendedPricingCatalogTransport(data: Data(Self.catalogJSON.utf8))
    let store = RemoteModelPricingCatalogStore(
      transport: transport,
      cacheDirectory: cacheDirectory,
      retryInterval: 3600
    )
    let now = Date(timeIntervalSince1970: 1_767_744_000)
    let codexKey = ModelPricingKey(provider: .codex, modelID: "future-gpt")
    let claudeKey = ModelPricingKey(provider: .claude, modelID: "future-claude")

    let codexTask = Task { await store.snapshot(for: [codexKey], now: now) }
    await transport.waitUntilRequestStarts()
    let claudeTask = Task { await store.snapshot(for: [claudeKey], now: now) }
    try? await Task.sleep(for: .milliseconds(10))
    await transport.resumeResponse()
    let codexSnapshot = await codexTask.value
    let claudeSnapshot = await claudeTask.value

    #expect(codexSnapshot.remote.pricing(for: codexKey) != nil)
    #expect(claudeSnapshot.remote.pricing(for: claudeKey) != nil)
    #expect(await transport.requestCount == 1)
  }

  private static let catalogJSON = """
  {
    "future-gpt": {
      "litellm_provider": "openai",
      "input_cost_per_token": 0.000001,
      "output_cost_per_token": 0.000002
    },
    "future-claude": {
      "litellm_provider": "anthropic",
      "input_cost_per_token": 0.000003,
      "output_cost_per_token": 0.000004
    }
  }
  """
}

private actor SuspendedPricingCatalogTransport: ProviderHTTPTransport {
  let data: Data
  private(set) var requestCount = 0
  private var requestStartedContinuation: CheckedContinuation<Void, Never>?
  private var responseContinuation: CheckedContinuation<Void, Never>?

  init(data: Data) {
    self.data = data
  }

  func waitUntilRequestStarts() async {
    guard requestCount == 0 else { return }
    await withCheckedContinuation { continuation in
      requestStartedContinuation = continuation
    }
  }

  func resumeResponse() {
    responseContinuation?.resume()
    responseContinuation = nil
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requestCount += 1
    requestStartedContinuation?.resume()
    requestStartedContinuation = nil
    await withCheckedContinuation { continuation in
      responseContinuation = continuation
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: nil,
      headerFields: ["ETag": "catalog-v1"]
    )!
    return (data, response)
  }
}
