import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountRefreshTests {
  @Test func concurrentCredentialRediscoveryRequestsShareOneDiscoveryPass() async throws {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Codex CLI",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    let discovery = GatedAccountRediscovery(account: account)
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      startsAutomatically: false
    )

    store.beginAccountRediscovery()
    let reload = try #require(store.inFlightAccountReload)
    store.beginAccountRediscovery()
    await discovery.waitUntilRequestStarts()

    #expect(await discovery.requestCount == 1)

    await discovery.resume()
    await reload.value

    #expect(await discovery.requestCount == 1)
    #expect(store.accounts[.codex] == [account])
  }

  @Test func externalLoginAndLogoutRefreshSettingsCredentialStateAndAccountPicker() async {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Codex CLI",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery())
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      startsAutomatically: false
    )

    await store.reloadAccounts()
    #expect(store.credentialDiscoveryState(for: .codex) == .absent)
    #expect(store.accounts[.codex] == [])

    discovery.update(StaticAccountDiscovery(accounts: [.codex: [account]]))
    await store.reloadAccounts()
    #expect(store.credentialDiscoveryState(for: .codex) == .present)
    #expect(store.accounts[.codex] == [account])

    discovery.update(StaticAccountDiscovery())
    await store.reloadAccounts()
    #expect(store.credentialDiscoveryState(for: .codex) == .absent)
    #expect(store.accounts[.codex] == [])
  }

  @Test func newerActivationRequestRerunsAnInFlightCredentialDiscovery() async throws {
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Codex CLI",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    let discovery = GatedAccountRediscovery(account: account)
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      startsAutomatically: false
    )

    store.beginAccountRediscovery()
    let reload = try #require(store.inFlightAccountReload)
    await discovery.waitUntilRequestStarts()
    await discovery.update(StaticAccountDiscovery())
    store.beginAccountRediscovery()
    await discovery.resume()
    await reload.value

    #expect(await discovery.requestCount == 2)
    #expect(store.credentialDiscoveryState(for: .codex) == .absent)
    #expect(store.accounts[.codex] == [])
  }

  @Test func implicitAndMonitoredRefreshesCarryTheLiveAccountsSavedCopyLink() async {
    let live = ProviderAccount(
      provider: .claude,
      displayName: "Claude Code",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      credentialIdentity: "live-fingerprint"
    )
    let saved = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:saved")
    )
    let recorder = CapturedRegistryIDRecorder()
    let descriptor = ProviderDescriptor(
      id: .claude,
      metadata: ProviderMetadata(displayName: "Claude", accent: .init(0.7, 0.4, 0.8), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingCapturedRegistryIDStrategy(recorder: recorder)] }
    )
    let discovery = StaticAccountDiscovery(
      accounts: [.claude: [live]],
      capturedCopies: [live.id: saved]
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      startsAutomatically: false
    )
    await store.reloadAccounts()

    await store.refresh()

    #expect(store.selectedAccounts[.claude] == nil)
    let ids = await recorder.ids
    #expect(ids == ["claude:saved", "claude:saved"])
  }

  @Test func refreshUsesPersistedSelectedAccount() async throws {
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let account = ProviderAccount(
      provider: .codex,
      displayName: "Selected",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json")
    )
    try selectionStore.save([.codex: account])
    let recorder = AccountRecorder()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: recorder)] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.refresh()

    #expect(await recorder.accounts == [account])
  }

  @Test func accountSwitchRejectsInFlightRefreshAndFetchesSelectedAccount() async throws {
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let firstAccount = ProviderAccount(
      provider: .codex,
      displayName: "First",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/tmp/first/auth.json")
    )
    let selectedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Selected",
      detail: "Test",
      credentialSource: .codexAuthFile(path: "/tmp/selected/auth.json")
    )
    try selectionStore.save([.codex: firstAccount])
    let strategy = AccountSwitchRaceStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    let initialRefresh = Task { await store.refresh() }
    await strategy.waitUntilFirstRequestStarts()
    store.selectAccount(selectedAccount, for: .codex)
    let selectedSnapshot = await Self.waitForSnapshot(
      in: store,
      account: selectedAccount.displayName,
      attempts: 10
    )
    let requestCountBeforeStaleRequestFinishes = await strategy.requestCount
    await strategy.resumeFirstRequest()
    await initialRefresh.value

    #expect(selectedSnapshot?.account == "Selected")
    #expect(selectedSnapshot?.primary?.usedPercent == 20)
    #expect(requestCountBeforeStaleRequestFinishes == 2)
  }

  @Test func reloadAccountsRefreshesPersistedCredentialIdentity() async throws {
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let source = ProviderCredentialSource.codexAuthFile(path: "/tmp/auth.json")
    let persistedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Persisted",
      detail: "Default",
      credentialSource: source,
      credentialIdentity: "old-account"
    )
    let refreshedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Refreshed",
      detail: "Default",
      credentialSource: source,
      credentialIdentity: "new-account"
    )
    try selectionStore.save([.codex: persistedAccount])
    let recorder = AccountRecorder()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: recorder)] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [refreshedAccount]]),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(store.selectedAccounts[.codex] == refreshedAccount)
    #expect(selectionStore.load()[.codex] == refreshedAccount)
  }

  private static func waitForSnapshot(
    in store: UsageStore,
    account: String,
    attempts: Int
  ) async -> UsageSnapshot? {
    for _ in 0 ..< attempts {
      if let snapshot = store.snapshots[.codex], snapshot.account == account {
        return snapshot
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }
}

private actor CapturedRegistryIDRecorder {
  private(set) var ids: [String?] = []

  func record(_ id: String?) {
    ids.append(id)
  }
}

private struct RecordingCapturedRegistryIDStrategy: ProviderFetchStrategy {
  let recorder: CapturedRegistryIDRecorder
  let id = "recording-captured-registry-id"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    await recorder.record(context.capturedRegistryID)
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        primary: RateWindow(kind: .session, usedPercent: 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}
