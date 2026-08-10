import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringRotationTests {
  @Test func verifiedRotationPreservesNonselectedLiveMonitorWhileCapturing() async throws {
    let directory = try TemporaryDirectory()
    let sourcePayload = claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
    let targetPayload = claudePayload(accessToken: "access-b", refreshToken: "refresh-b")
    let payload = AutomaticCapturePayloadBox(sourcePayload)
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let source = try #require(await discovery.accounts(for: .claude).first {
      !$0.credentialSource.isCaptured
    })
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("selection.json")
    )
    // Monitoring must follow a verified rotation even when another account drives the dashboard.
    try selectionStore.save([:])
    let monitoringStore = ProviderAccountMonitoringStore(
      url: directory.url.appendingPathComponent("monitoring.json")
    )
    try monitoringStore.save([.claude: [source]])
    let store = monitoringRotationStore(
      discovery: discovery,
      selectionStore: selectionStore,
      monitoringStore: monitoringStore,
      payload: payload,
      registry: registry
    )

    payload.value = targetPayload
    let target = try #require(await discovery.accounts(for: .claude).first {
      !$0.credentialSource.isCaptured
    })
    store.completedCredentialTransitions[.claude] = [
      source.credentialScopeID: [target.credentialScopeID],
    ]

    await store.reloadAccounts()

    let saved = try #require(registry.load().first)
    #expect(store.monitoredAccounts[.claude] == [target])
    #expect(try monitoringStore.load()[.claude] == [saved.providerAccount])
  }
}

@MainActor
private func monitoringRotationStore(
  discovery: ProviderAccountDiscovery,
  selectionStore: ProviderAccountSelectionStore,
  monitoringStore: ProviderAccountMonitoringStore,
  payload: AutomaticCapturePayloadBox,
  registry: CapturedAccountStore
) -> UsageStore {
  UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountSelectionStore: selectionStore,
    accountMonitoringStore: monitoringStore,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "monitored-account",
      email: "monitored@example.com"
    ),
    claudeCredentialLoader: { source in
      automaticCaptureClaudeCredentials(
        source: source,
        keychainPayload: payload.value,
        registry: registry
      )
    },
    startsAutomatically: false
  )
}
