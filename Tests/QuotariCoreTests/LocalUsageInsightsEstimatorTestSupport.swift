import Foundation
@testable import QuotariCore
import Testing

struct InsightsEstimatorFixture {
  let root: URL
  let codexHome: URL
  let cache: URL
  let now: Date
  let usageURL: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-insights-estimator-\(UUID().uuidString)", isDirectory: true)
    codexHome = root.appendingPathComponent("codex", isDirectory: true)
    cache = root.appendingPathComponent("cache", isDirectory: true)
    let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
    try codexAuthPayload(accessToken: "access", accountID: "account")
      .write(to: codexHome.appendingPathComponent("auth.json"))

    usageURL = sessions.appendingPathComponent("usage.jsonl")
    try writeCodexUsage(timestamp: "2026-07-08T09:00:00Z")
  }

  func writeCodexUsage(timestamp: String) throws {
    let line: [String: Any] = [
      "type": "event_msg",
      "timestamp": timestamp,
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
    try data.write(to: usageURL)
  }

  func codexAccount(identity: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: "Test",
      credentialSource: .codexAuthFile(path: codexHome.appendingPathComponent("auth.json").path),
      credentialIdentity: identity
    )
  }

  func estimator() -> LocalUsageCostEstimator {
    .testing(
      environment: ["CODEX_HOME": codexHome.path],
      homeDirectory: root,
      cacheDirectory: cache
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}

struct ClaudeInsightsEstimatorFixture {
  let root: URL
  let config: URL
  let cache: URL
  let now: Date

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-claude-insights-\(UUID().uuidString)", isDirectory: true)
    config = root.appendingPathComponent(".claude", isDirectory: true)
    cache = root.appendingPathComponent("cache", isDirectory: true)
    let projects = config.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    now = try #require(LenientDateParser.parse("2026-07-08T12:00:00Z"))
    try Data(
      #"{"claudeAiOauth":{"accessToken":"current-token","refreshToken":"refresh"}}"#.utf8
    ).write(to: config.appendingPathComponent(".credentials.json"))
    let usageLine = [
      #"{"type":"assistant","timestamp":"2026-07-08T09:00:00Z","requestId":"request","#,
      #""message":{"model":"claude-sonnet-4","usage":{"cache_read_input_tokens":80}}}"#,
    ].joined()
    try Data(usageLine.utf8).write(to: projects.appendingPathComponent("usage.jsonl"))
  }

  func writePlaceholderOnlyUsage() throws {
    try writePlaceholderUsage(
      to: config.appendingPathComponent("projects/usage.jsonl"),
      requestID: "request"
    )
  }

  func writeAdditionalPlaceholderUsage() throws {
    try writePlaceholderUsage(
      to: config.appendingPathComponent("projects/placeholder.jsonl"),
      requestID: "placeholder-request"
    )
  }

  private func writePlaceholderUsage(to url: URL, requestID: String) throws {
    let usageLine = [
      #"{"type":"assistant","timestamp":"2026-07-08T09:00:00Z","requestId":"\#(requestID)","#,
      #""message":{"model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":20}}}"#,
    ].joined()
    try Data(usageLine.utf8).write(to: url)
  }

  func account(identity: String) -> ProviderAccount {
    ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: "Test",
      credentialSource: .claudeCredentialsFile(path: config.appendingPathComponent(".credentials.json").path),
      credentialIdentity: identity
    )
  }

  func estimator() -> LocalUsageCostEstimator {
    .testing(environment: [:], homeDirectory: root, cacheDirectory: cache)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}

actor BlockingPricingCatalogProvider: ModelPricingCatalogProviding {
  private var response: CheckedContinuation<ModelPricingCatalogSnapshot, Never>?
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []

  func snapshot(
    for keys: Set<ModelPricingKey>,
    now: Date
  ) async -> ModelPricingCatalogSnapshot {
    await withCheckedContinuation { continuation in
      response = continuation
      requestWaiters.forEach { $0.resume() }
      requestWaiters.removeAll()
    }
  }

  func waitUntilRequested() async {
    guard response == nil else { return }
    await withCheckedContinuation { requestWaiters.append($0) }
  }

  func finish() {
    response?.resume(returning: .bundledOnly)
    response = nil
  }
}

struct BundledPricingCatalogProvider: ModelPricingCatalogProviding {
  func snapshot(
    for keys: Set<ModelPricingKey>,
    now: Date
  ) async -> ModelPricingCatalogSnapshot {
    .bundledOnly
  }
}

final class BlockingCacheMutationHook: @unchecked Sendable {
  private let lock = NSLock()
  private let resume = DispatchSemaphore(value: 0)
  private var didReach = false
  private var reachWaiters: [CheckedContinuation<Void, Never>] = []

  func pause() {
    let waiters = lock.withLock {
      didReach = true
      defer { reachWaiters.removeAll() }
      return reachWaiters
    }
    waiters.forEach { $0.resume() }
    resume.wait()
  }

  func waitUntilReached() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        if didReach {
          return true
        }
        reachWaiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func finish() {
    resume.signal()
  }
}
