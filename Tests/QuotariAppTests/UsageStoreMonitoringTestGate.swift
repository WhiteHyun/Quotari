import Foundation
@testable import QuotariCore

actor MonitoringUsageGate {
  private var firstRequestStarted = false
  private var firstRequestReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func suspendFirstRequest() async {
    guard !firstRequestStarted else { return }
    firstRequestStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    guard !firstRequestReleased else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitUntilFirstRequestStarts() async {
    guard !firstRequestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resumeFirstRequest() {
    firstRequestReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

actor MonitoringUsageRecorder {
  private(set) var names: [String] = []

  func record(_ account: ProviderAccount?) {
    names.append(account?.displayName ?? "Automatic")
  }
}

struct MonitoringUsageStrategy: ProviderFetchStrategy {
  let recorder: MonitoringUsageRecorder
  let automaticCredentialScopeID: String?
  let automaticAccountName: String?
  let explicitCredentialScopeID: String?
  let automaticTransitionSourceScopeIDs: Set<String>
  let gate: MonitoringUsageGate?
  let id = "monitoring-usage"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    await gate?.suspendFirstRequest()
    await recorder.record(context.account)
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        account: context.account?.displayName ?? automaticAccountName,
        primary: RateWindow(kind: .session, usedPercent: 25),
        secondary: nil,
        updatedAt: context.now
      ),
      sourceLabel: "Test",
      credentialScopeID: context.account == nil
        ? automaticCredentialScopeID
        : explicitCredentialScopeID ?? context.account?.credentialScopeID,
      credentialTransitionSourceScopeIDs: context.account == nil
        ? automaticTransitionSourceScopeIDs
        : []
    )
  }
}
