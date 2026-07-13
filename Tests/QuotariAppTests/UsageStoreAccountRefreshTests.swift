import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountRefreshTests {
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

  @Test func reloadAccountsReconcilesSelectedSavedAccountToItsLiveCopy() async throws {
    // The saved copy of an identity that logged back into the CLI is hidden
    // from discovery; a selection still pointing at it must move to the live
    // account rather than re-listing the stale snapshot next to it.
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let savedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Saved",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:acct-1")
    )
    let liveAccount = ProviderAccount(
      provider: .codex,
      displayName: "Live",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json"),
      credentialIdentity: "acct-1"
    )
    try selectionStore.save([.codex: savedAccount])
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: AccountRecorder())] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [liveAccount]],
        liveEquivalents: [savedAccount.id: liveAccount]
      ),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(store.selectedAccounts[.codex] == liveAccount)
    #expect(store.accounts[.codex] == [liveAccount])
    // The persisted selection stays on the saved account, so a slot reused
    // by another login later falls back to it instead of being followed.
    #expect(selectionStore.load()[.codex] == savedAccount)
  }

  @Test func selectionFallsBackToTheSavedCopyWhenTheSlotIsReused() async throws {
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let savedAccount = ProviderAccount(
      provider: .codex,
      displayName: "Saved",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:acct-1")
    )
    let liveSame = ProviderAccount(
      provider: .codex,
      displayName: "Live",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json"),
      credentialIdentity: "acct-1"
    )
    try selectionStore.save([.codex: savedAccount])
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: AccountRecorder())] }
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.codex: [liveSame]],
      liveEquivalents: [savedAccount.id: liveSame]
    ))
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )

    await store.reloadAccounts()
    #expect(store.selectedAccounts[.codex] == liveSame)

    // The CLI slot is reused by a different login: the saved row is visible
    // again and the selection must return to it, not follow the slot.
    let liveOther = ProviderAccount(
      provider: .codex,
      displayName: "Other",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json"),
      credentialIdentity: "acct-2"
    )
    discovery.update(StaticAccountDiscovery(accounts: [.codex: [liveOther, savedAccount]]))
    await store.reloadAccounts()

    #expect(store.selectedAccounts[.codex] == savedAccount)
    #expect(selectionStore.load()[.codex] == savedAccount)
  }

  @Test func liveAccountWithASavedCopyIsNotCapturable() async {
    // Once the current login is saved, its registry row is hidden — the live
    // row must stop offering Save instead of re-capturing forever.
    let liveAccount = ProviderAccount(
      provider: .codex,
      displayName: "Live",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/auth.json"),
      credentialIdentity: "acct-1"
    )
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: AccountRecorder())] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [liveAccount]],
        capturedCopyIDs: [liveAccount.id]
      ),
      startsAutomatically: false
    )
    #expect(store.isCapturable(liveAccount))

    await store.reloadAccounts()

    #expect(!store.isCapturable(liveAccount))
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

private struct EmptyCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}

private actor AccountRecorder {
  private(set) var accounts: [ProviderAccount?] = []

  func record(_ account: ProviderAccount?) {
    accounts.append(account)
  }
}

private struct RecordingAccountStrategy: ProviderFetchStrategy {
  let recorder: AccountRecorder
  let id = "recording"
  let kind = ProviderFetchKind.mock

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    await recorder.record(context.account)
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

private actor AccountSwitchRaceStrategy: ProviderFetchStrategy {
  let id = "account-switch-race"
  let kind = ProviderFetchKind.api

  private(set) var requestCount = 0
  private var firstRequestContinuation: CheckedContinuation<Void, Never>?
  private var firstRequestStartedContinuation: CheckedContinuation<Void, Never>?

  func waitUntilFirstRequestStarts() async {
    guard requestCount == 0 else { return }
    await withCheckedContinuation { continuation in
      firstRequestStartedContinuation = continuation
    }
  }

  func resumeFirstRequest() {
    firstRequestContinuation?.resume()
    firstRequestContinuation = nil
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let isFirstRequest = requestCount == 0
    requestCount += 1
    if isFirstRequest {
      firstRequestStartedContinuation?.resume()
      firstRequestStartedContinuation = nil
      await withCheckedContinuation { continuation in
        firstRequestContinuation = continuation
      }
    }

    let isSelected = context.account?.displayName == "Selected"
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: "Test",
        account: context.account?.displayName,
        primary: RateWindow(kind: .session, usedPercent: isSelected ? 20 : 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}

private final class TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-usage-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}
