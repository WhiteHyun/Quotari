import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

func codexDescriptor() -> ProviderDescriptor {
  ProviderDescriptor(
    id: .codex,
    metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
    pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: AccountRecorder())] }
  )
}

func savedCodexAccount(displayName: String = "Saved") -> ProviderAccount {
  ProviderAccount(
    provider: .codex,
    displayName: displayName,
    detail: "Saved in Quotari",
    credentialSource: .quotariRegistry(id: "codex:acct-1")
  )
}

func liveCodexAccount(identity: String, displayName: String = "Live") -> ProviderAccount {
  ProviderAccount(
    provider: .codex,
    displayName: displayName,
    detail: "Default",
    credentialSource: .codexAuthFile(path: "/tmp/auth.json"),
    credentialIdentity: identity
  )
}

/// Saves a Codex snapshot into `registry` and returns the registry account
/// row it would appear as in discovery.
@discardableResult
func saveCodexSnapshot(
  _ registry: CapturedAccountStore,
  id: String,
  accountID: String? = "acct-saved"
) throws -> ProviderAccount {
  let payload = if let accountID {
    #"{"tokens":{"access_token":"saved-tok","account_id":"\#(accountID)","refresh_token":"saved-ref"}}"#
  } else {
    #"{"tokens":{"access_token":"saved-tok","refresh_token":"saved-ref"}}"#
  }
  try registry.save(CapturedAccount(
    id: id, provider: .codex, displayName: "Saved", detail: "Personal",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .codexAuthFile(path: "/tmp/old.json"),
    payload: Data(payload.utf8)
  ))
  return ProviderAccount(
    provider: .codex, displayName: "Saved", detail: "Saved in Quotari",
    credentialSource: .quotariRegistry(id: id)
  )
}

func liveCodexAccount(atWrittenSlot home: URL, identity: String? = nil) -> ProviderAccount {
  ProviderAccount(
    provider: .codex, displayName: "Live", detail: "Default",
    credentialSource: .codexAuthFile(path: home.appendingPathComponent(".codex/auth.json").standardizedFileURL.path),
    credentialIdentity: identity
  )
}

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
    let savedAccount = savedCodexAccount()
    let liveAccount = liveCodexAccount(identity: "acct-1")
    try selectionStore.save([.codex: savedAccount])
    let descriptor = codexDescriptor()
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
    let savedAccount = savedCodexAccount()
    let liveSame = liveCodexAccount(identity: "acct-1")
    try selectionStore.save([.codex: savedAccount])
    let descriptor = codexDescriptor()
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
    let liveOther = liveCodexAccount(identity: "acct-2", displayName: "Other")
    discovery.update(StaticAccountDiscovery(accounts: [.codex: [liveOther, savedAccount]]))
    await store.reloadAccounts()

    #expect(store.selectedAccounts[.codex] == savedAccount)
    #expect(selectionStore.load()[.codex] == savedAccount)
  }

  @Test func reloadFlagsTheSavedCopyBehindALiveAccount() async {
    let liveAccount = liveCodexAccount(identity: "acct-1")
    let savedCopy = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:acct-1")
    )
    let descriptor = codexDescriptor()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [liveAccount]],
        capturedCopies: [liveAccount.id: savedCopy]
      ),
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(store.capturedEquivalents[liveAccount.id] == savedCopy)
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
    let descriptor = codexDescriptor()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [live]],
        capturedCopies: [live.id: ProviderAccount(
          provider: .codex,
          displayName: "Codex",
          detail: "Saved in Quotari",
          credentialSource: .quotariRegistry(id: "codex:acct-1")
        )]
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

  @Test func selectingTheLiveStandInAnchorsToTheSavedCopy() async throws {
    // The saved row is hidden while its identity is live, so picking the
    // visible live row means picking the saved account.
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let live = liveCodexAccount(identity: "acct-1")
    let savedCopy = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:acct-1")
    )
    let descriptor = codexDescriptor()
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [live]],
        capturedCopies: [live.id: savedCopy]
      ),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )
    await store.reloadAccounts()

    store.selectAccount(live, for: .codex)

    #expect(store.selectedAccounts[.codex] == live)
    #expect(selectionStore.load()[.codex] == savedCopy)
  }

  @Test func periodicRefreshReconcilesAStandInSelection() async throws {
    // A slot reused between account reloads must not keep feeding the timer
    // path: refresh() rediscovers first whenever a stand-in is selected.
    let directory = try TemporaryDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let savedAccount = savedCodexAccount()
    let liveSame = liveCodexAccount(identity: "acct-1")
    try selectionStore.save([.codex: savedAccount])
    let descriptor = codexDescriptor()
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

    let liveOther = liveCodexAccount(identity: "acct-2", displayName: "Other")
    discovery.update(StaticAccountDiscovery(accounts: [.codex: [liveOther, savedAccount]]))
    await store.refresh()

    #expect(store.selectedAccounts[.codex] == savedAccount)
  }
}
