import Foundation
@testable import QuotariCore
import Testing

struct ProviderFetchTransitionTests {
  @Test func fallbackSuccessRetainsAnEarlierCredentialTransition() async throws {
    let pipeline = ProviderFetchPipeline { _ in
      [
        TransitionFailureStrategy(allowsFallback: true),
        TransitionFallbackStrategy(),
      ]
    }

    let result = try await pipeline.fetch(context()).get()

    #expect(result.sourceKind == .mock)
    #expect(result.credentialScopeID == nil)
    #expect(result.credentialTransitionTargetScopeID == "scope-b")
    #expect(result.credentialTransitionSourceScopeIDs == ["scope-a"])
  }

  @Test func terminalFailureRetainsTheCredentialTransitionAndOriginalMessage() async {
    let pipeline = ProviderFetchPipeline { _ in
      [TransitionFailureStrategy(allowsFallback: false)]
    }

    let result = await pipeline.fetch(context())
    guard case let .failure(error) = result,
          let transition = error as? ProviderFetchTransitionError
    else {
      Issue.record("Expected a transition-bearing failure")
      return
    }

    #expect(transition.credentialTransitionTargetScopeID == "scope-b")
    #expect(transition.credentialTransitionSourceScopeIDs == ["scope-a"])
    #expect(transition.localizedDescription == "Usage failed after refresh.")
  }

  @Test func cancellationAfterRotationRetainsTheCredentialTransition() async {
    let pipeline = ProviderFetchPipeline { _ in
      [
        TransitionCancellationStrategy(),
        TransitionFallbackStrategy(),
      ]
    }

    let result = await pipeline.fetch(context())
    guard case let .failure(error) = result,
          let transition = error as? ProviderFetchTransitionError
    else {
      Issue.record("Expected a transition-bearing cancellation")
      return
    }

    #expect(transition.underlying is CancellationError)
    #expect(transition.credentialTransitionTargetScopeID == "scope-b")
    #expect(transition.credentialTransitionSourceScopeIDs == ["scope-a"])
  }

  @Test func taskCancellationBetweenStrategiesRetainsTheCredentialTransition() async {
    let gate = TransitionFailureGate()
    let pipeline = ProviderFetchPipeline { _ in
      [
        GatedTransitionFailureStrategy(gate: gate),
        TransitionFallbackStrategy(),
      ]
    }
    let task = Task { await pipeline.fetch(context()) }
    await gate.waitUntilRequestStarts()

    task.cancel()
    await gate.resume()

    let result = await task.value
    guard case let .failure(error) = result,
          let transition = error as? ProviderFetchTransitionError
    else {
      Issue.record("Expected a transition-bearing cancellation")
      return
    }
    #expect(transition.underlying is CancellationError)
    #expect(transition.credentialTransitionTargetScopeID == "scope-b")
    #expect(transition.credentialTransitionSourceScopeIDs == ["scope-a"])
  }

  @Test func fallbackCancellationRetainsAnEarlierCredentialTransition() async {
    let pipeline = ProviderFetchPipeline { _ in
      [
        TransitionFailureStrategy(allowsFallback: true),
        BareCancellationStrategy(),
      ]
    }

    let result = await pipeline.fetch(context())
    guard case let .failure(error) = result,
          let transition = error as? ProviderFetchTransitionError
    else {
      Issue.record("Expected a transition-bearing cancellation")
      return
    }
    #expect(transition.underlying is CancellationError)
    #expect(transition.credentialTransitionTargetScopeID == "scope-b")
    #expect(transition.credentialTransitionSourceScopeIDs == ["scope-a"])
  }

  private func context() -> ProviderFetchContext {
    ProviderFetchContext(provider: .claude, now: Date(timeIntervalSince1970: 0))
  }
}

private actor TransitionFailureGate {
  private var requestStarted = false
  private var isReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilRequestStarts() async {
    guard !requestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func beginRequest() async {
    requestStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    guard !isReleased else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func resume() {
    isReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private struct GatedTransitionFailureStrategy: ProviderFetchStrategy {
  let id = "gated-transition-failure"
  let kind = ProviderFetchKind.oauth
  let gate: TransitionFailureGate

  func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
    await gate.beginRequest()
    throw ProviderFetchTransitionError(
      underlying: TransitionUsageFailure(),
      credentialTransitionTargetScopeID: "scope-b",
      credentialTransitionSourceScopeIDs: ["scope-a"]
    )
  }
}

private struct BareCancellationStrategy: ProviderFetchStrategy {
  let id = "bare-cancellation"
  let kind = ProviderFetchKind.oauth

  func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
    throw CancellationError()
  }
}

private struct TransitionCancellationStrategy: ProviderFetchStrategy {
  let id = "transition-cancellation"
  let kind = ProviderFetchKind.oauth

  func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
    throw ProviderFetchTransitionError(
      underlying: CancellationError(),
      credentialTransitionTargetScopeID: "scope-b",
      credentialTransitionSourceScopeIDs: ["scope-a"]
    )
  }
}

private struct TransitionFailureStrategy: ProviderFetchStrategy {
  let id = "transition-failure"
  let kind = ProviderFetchKind.oauth
  let allowsFallback: Bool

  func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
    throw ProviderFetchTransitionError(
      underlying: TransitionUsageFailure(),
      credentialTransitionTargetScopeID: "scope-b",
      credentialTransitionSourceScopeIDs: ["scope-a"]
    )
  }

  func shouldFallback(on _: Error) -> Bool {
    allowsFallback
  }
}

private struct TransitionFallbackStrategy: ProviderFetchStrategy {
  let id = "transition-fallback"
  let kind = ProviderFetchKind.mock

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Fallback"
    )
  }
}

private struct TransitionUsageFailure: LocalizedError {
  var errorDescription: String? {
    "Usage failed after refresh."
  }
}
