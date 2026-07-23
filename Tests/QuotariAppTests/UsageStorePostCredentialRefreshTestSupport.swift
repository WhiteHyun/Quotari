import Foundation
@testable import Quotari
@testable import QuotariCore

func liveClaudeAccount(credentialIdentity: String) -> ProviderAccount {
  ProviderAccount(
    provider: .claude,
    displayName: "Claude",
    detail: "Keychain",
    credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    credentialIdentity: credentialIdentity
  )
}

func postCredentialDescriptor(
  provider: UsageProvider = .claude,
  strategy: GatedPostCredentialUsageStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: provider,
    metadata: ProviderMetadata(
      displayName: provider == .claude ? "Claude" : "Codex",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

func stepwisePostCredentialDescriptor(
  strategy: StepwisePostCredentialUsageStrategy
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
}

actor GatedPostCredentialUsageStrategy: ProviderFetchStrategy {
  nonisolated let id = "gated-post-credential"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0
  private var released = false
  private var activeRequests = 0
  private(set) var maximumConcurrentRequests = 0
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    activeRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    defer { activeRequests -= 1 }
    let ready = startWaiters.filter { requestCount >= $0.0 }
    startWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    if !released {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Gated"
    )
  }

  func waitUntilRequestStarts(count: Int = 1) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { startWaiters.append((count, $0)) }
  }

  func resume() {
    released = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

actor StepwisePostCredentialUsageStrategy: ProviderFetchStrategy {
  nonisolated let id = "stepwise-post-credential"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0
  private var activeRequests = 0
  private(set) var maximumConcurrentRequests = 0
  private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var releasePermits = 0

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    activeRequests += 1
    maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
    defer { activeRequests -= 1 }
    let ready = startWaiters.filter { requestCount >= $0.0 }
    startWaiters.removeAll { requestCount >= $0.0 }
    ready.forEach { $0.1.resume() }
    if releasePermits > 0 {
      releasePermits -= 1
    } else {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stepwise"
    )
  }

  func waitUntilRequestStarts(count: Int) async {
    guard requestCount < count else { return }
    await withCheckedContinuation { startWaiters.append((count, $0)) }
  }

  func resumeNext() {
    guard !releaseWaiters.isEmpty else {
      releasePermits += 1
      return
    }
    releaseWaiters.removeFirst().resume()
  }
}

actor PostCredentialRefreshGate {
  private(set) var requestedDurations: [Duration] = []
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func sleep(for duration: Duration) async throws {
    requestedDurations.append(duration)
    let ready = requestWaiters.filter { requestedDurations.count >= $0.0 }
    requestWaiters.removeAll { requestedDurations.count >= $0.0 }
    ready.forEach { $0.1.resume() }
    await withCheckedContinuation { continuations.append($0) }
  }

  func waitUntilRequested(count: Int = 1) async {
    guard requestedDurations.count < count else { return }
    await withCheckedContinuation { requestWaiters.append((count, $0)) }
  }

  func resumeAll() {
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }
}
