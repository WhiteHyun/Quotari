import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

/// Logical selection across saved copies and live logins: reconciliation,
/// slot-reuse fallback, capture anchoring, and hidden-copy upkeep.
@MainActor
struct UsageStoreSelectionReconcileTests {
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

  @Test func capturingTheSelectedLiveAccountAnchorsTheSelectionToTheSavedCopy() async throws {
    let directory = try TemporaryDirectory()
    let authURL = directory.url.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"tok","account_id":"acct-1","refresh_token":"ref"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let live = ProviderAccount(
      provider: .codex,
      displayName: "Live",
      detail: "Default",
      credentialSource: .codexAuthFile(path: authURL.path),
      credentialIdentity: "acct-1"
    )
    let originID = ProviderAccount.id(provider: .codex, source: .quotariRegistry(id: "codex:acct-1"))
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
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
        accounts: [.codex: [live]],
        liveEquivalents: [originID: live]
      ),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )
    store.selectAccount(live, for: .codex)

    await store.captureAccount(live)

    // Runtime selection stays on the live login; the persisted selection is
    // anchored to the saved copy so a slot reuse falls back to it.
    #expect(store.selectedAccounts[.codex] == live)
    #expect(selectionStore.load()[.codex]?.credentialSource == .quotariRegistry(id: "codex:acct-1"))
  }

  @Test func periodicRefreshSyncsHiddenSavedCopies() async throws {
    let directory = try TemporaryDirectory()
    let authURL = directory.url.appendingPathComponent("auth.json")
    try Data(#"{"tokens":{"access_token":"tok-1","account_id":"acct-1","refresh_token":"ref-1"}}"#.utf8)
      .write(to: authURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
    let live = ProviderAccount(
      provider: .codex,
      displayName: "Live",
      detail: "Default",
      credentialSource: .codexAuthFile(path: authURL.path),
      credentialIdentity: "acct-1"
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "codex:acct-1",
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .codexAuthFile(path: authURL.path),
      payload: Data(#"{"tokens":{"access_token":"tok-1","account_id":"acct-1","refresh_token":"ref-1"}}"#.utf8)
    ))
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: AccountRecorder())] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [live]],
        capturedCopyIDs: [live.id]
      ),
      accountCapture: .inMemoryForTesting(capturedAccounts: registry),
      startsAutomatically: false
    )
    await store.reloadAccounts() // flags the live account as having a saved copy

    // The CLI rotates its tokens between account reloads; a periodic usage
    // refresh alone must keep the hidden copy in sync.
    try Data(#"{"tokens":{"access_token":"tok-2","account_id":"acct-1","refresh_token":"ref-2"}}"#.utf8)
      .write(to: authURL)
    await store.refresh()

    let credentials = try CodexCredentialsStore.load(
      source: .quotariRegistry(id: "codex:acct-1"),
      capturedAccounts: registry
    )
    #expect(credentials.accessToken == "tok-2")
    #expect(credentials.refreshToken == "ref-2")
  }
}
