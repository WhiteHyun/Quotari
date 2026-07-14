import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreSwitchRediscoveryTests {
  @Test func switchDrainsInFlightAccountRediscoveryBeforeWriting() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedAccount = try saveCodexSnapshot(registry, id: "codex:acct-saved")
    let liveAfterSwitch = liveCodexAccount(atWrittenSlot: home, identity: "acct-saved")
    let authURL = home.appendingPathComponent(".codex/auth.json")
    let discovery = GatedSwitchDiscovery(
      beforeSwitch: StaticAccountDiscovery(accounts: [.codex: [savedAccount]]),
      afterSwitch: StaticAccountDiscovery(
        accounts: [.codex: [liveAfterSwitch]],
        liveEquivalents: [savedAccount.id: liveAfterSwitch],
        capturedCopies: [liveAfterSwitch.id: savedAccount]
      ),
      writtenCredentialURL: authURL,
      preWriteRequestCount: 2
    )
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    await store.reloadAccounts()

    store.beginAccountRediscovery()
    await discovery.waitUntilSwitchReloadStarts()
    let switching = Task { await store.switchCLIAccount(to: savedAccount) }
    #expect(await Self.waitUntilSwitchStarts(store))

    let queuedRequest = store.accountRediscoveryRequest
    let queuedReload = Task { await store.reloadAccounts() }
    #expect(await Self.waitUntilRediscoveryIsQueued(store, after: queuedRequest))
    store.beginAccountRediscovery()
    #expect(!FileManager.default.fileExists(atPath: authURL.path))

    await discovery.resumeSwitchReload()
    await switching.value
    await queuedReload.value

    #expect(FileManager.default.fileExists(atPath: authURL.path))
    #expect(await discovery.postSwitchRequestSawCredential == true)
    #expect(store.captureErrors[.codex] == nil)
    #expect(store.selectedAccounts[.codex] == liveAfterSwitch)
  }

  @Test func dashboardRefreshQueuesRediscoveryBehindTheSwitchGate() async {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Saved Codex",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:saved")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      costEstimator: EmptyCostEstimator(),
      startsAutomatically: false
    )
    store.reconciledSelectionOrigins[.codex] = account
    store.isSwitching = true
    let request = store.accountRediscoveryRequest

    let canRefresh = await store.prepareReconciledAccountsForRefresh()

    #expect(!canRefresh)
    #expect(store.accountRediscoveryRequest == request + 1)
    #expect(store.inFlightAccountReload == nil)
    store.isSwitching = false
    store.startQueuedAccountRediscoveryIfNeeded()
    await store.inFlightAccountReload?.value
  }

  @Test func switchGateClosingDuringRediscoveryStopsTheDashboardFetch() async throws {
    let live = ProviderAccount(
      provider: .codex,
      displayName: "Codex CLI",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved Codex",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:saved")
    )
    let discovery = GatedAccountRediscovery(account: live)
    let recorder = AccountRecorder()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: recorder)] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      startsAutomatically: false
    )
    store.reconciledSelectionOrigins[.codex] = saved

    store.beginRefresh()
    let refresh = try #require(store.inFlightRefresh)
    await discovery.waitUntilRequestStarts()
    store.isSwitching = true
    await discovery.resume()
    await refresh.value

    #expect(await recorder.accounts.isEmpty)
    #expect(store.completedAccountRediscoveryRequest < store.accountRediscoveryRequest)
    store.isSwitching = false
    store.startQueuedAccountRediscoveryIfNeeded()
    await store.inFlightAccountReload?.value
  }

  @Test func drainableRediscoveryLeavesPostGateRequestsQueued() async throws {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Codex CLI",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    let discovery = GatedAccountRediscovery(account: account)
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      startsAutomatically: false
    )

    store.beginAccountRediscovery()
    let reload = try #require(store.inFlightAccountReload)
    let drainableRequest = store.accountRediscoveryRequest
    store.isSwitching = true
    let queuedReload = Task { await store.reloadAccounts() }
    #expect(await Self.waitUntilRediscoveryIsQueued(store, after: drainableRequest))
    store.beginAccountRediscovery()
    await discovery.waitUntilRequestStarts()
    await discovery.resume()
    await reload.value

    #expect(store.accounts[.codex] == [account])
    #expect(store.completedAccountRediscoveryRequest == drainableRequest)
    #expect(await discovery.requestCount == 1)
    #expect(store.inFlightAccountReload == nil)
    store.isSwitching = false
    store.startQueuedAccountRediscoveryIfNeeded()
    await queuedReload.value
    #expect(await discovery.requestCount == 2)
  }

  private static func waitUntilSwitchStarts(_ store: UsageStore) async -> Bool {
    for _ in 0 ..< 100 {
      if store.isSwitching {
        return true
      }
      await Task.yield()
    }
    return store.isSwitching
  }

  private static func waitUntilRediscoveryIsQueued(_ store: UsageStore, after request: UInt) async -> Bool {
    for _ in 0 ..< 100 {
      if store.accountRediscoveryRequest > request {
        return true
      }
      await Task.yield()
    }
    return store.accountRediscoveryRequest > request
  }
}
