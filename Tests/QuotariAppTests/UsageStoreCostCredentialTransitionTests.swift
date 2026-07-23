import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreCostCredentialTransitionTests {
  @Test func forwardsAProvenCredentialRotationToTheLocalCostEstimator() async throws {
    let source = ProviderCredentialSource.claudeCredentialsFile(path: "/tmp/quotari-claude/.credentials.json")
    let previousAccount = ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "previous-token"
    )
    let rotatedAccount = ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: nil,
      credentialSource: source,
      credentialIdentity: "rotated-token"
    )
    let estimator = TransitionCostEstimator()
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.claude: previousAccount])
    let store = UsageStore.isolatedForTesting(
      providers: [
        ProviderDescriptor(
          id: .claude,
          metadata: ProviderMetadata(
            displayName: "Claude",
            accent: .init(0.8, 0.5, 0.2),
            supportsWeekly: true
          ),
          pipeline: ProviderFetchPipeline { _ in
            [
              CredentialRotatingUsageStrategy(
                previousScopeID: previousAccount.credentialScopeID,
                rotatedScopeID: rotatedAccount.credentialScopeID
              ),
            ]
          }
        ),
      ],
      costEstimator: estimator,
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [previousAccount]]),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.reloadAccounts()
    await store.selectionRefreshTasks[.claude]?.value
    await store.refresh()
    let transition = try await estimator.waitForTransition()

    #expect(transition == UsageCostCredentialTransition(
      targetScopeID: rotatedAccount.credentialScopeID,
      sourceScopeIDs: [previousAccount.credentialScopeID]
    ))
  }
}

private actor TransitionCostEstimator: UsageCostEstimating {
  private var transition: UsageCostCredentialTransition?

  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }

  func costRefreshOutcome(
    provider: UsageProvider,
    account: ProviderAccount?,
    credentialTransition: UsageCostCredentialTransition?,
    now: Date,
    historyDays: Int
  ) async -> UsageCostRefreshOutcome {
    transition = credentialTransition
    return .unavailable
  }

  func waitForTransition() async throws -> UsageCostCredentialTransition? {
    for _ in 0 ..< 100 {
      if let transition {
        return transition
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw TimeoutError()
  }
}

private struct CredentialRotatingUsageStrategy: ProviderFetchStrategy {
  let id = "credential-rotating-usage"
  let kind = ProviderFetchKind.oauth
  let previousScopeID: String
  let rotatedScopeID: String

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stub",
      credentialScopeID: rotatedScopeID,
      credentialTransitionTargetScopeID: rotatedScopeID,
      credentialTransitionSourceScopeIDs: [previousScopeID]
    )
  }
}

private struct TimeoutError: Error {}
