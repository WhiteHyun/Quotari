import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreSwitchTests {
  @Test func switchingWritesTheCLISlotAndSelectsTheNewLiveLogin() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedAccount = try saveCodexSnapshot(registry, id: "codex:acct-saved")
    let liveAfterSwitch = liveCodexAccount(atWrittenSlot: home, identity: "acct-saved")
    let selectionStore = ProviderAccountSelectionStore(
      url: home.appendingPathComponent("ProviderAccounts.json")
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.codex: [savedAccount]]
    ))
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    await store.reloadAccounts()

    // After the write, rediscovery would show the live login hiding the
    // saved row — script that world before invoking the switch's reload.
    discovery.update(StaticAccountDiscovery(
      accounts: [.codex: [liveAfterSwitch]],
      liveEquivalents: [savedAccount.id: liveAfterSwitch],
      capturedCopies: [liveAfterSwitch.id: savedAccount]
    ))
    await store.switchCLIAccount(to: savedAccount)

    // The CLI slot now holds the saved account's credentials…
    let slot = try JSONSerialization.jsonObject(
      with: Data(contentsOf: home.appendingPathComponent(".codex/auth.json"))
    ) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-saved")
    // …and the selection is the live stand-in, anchored to the saved copy.
    #expect(store.captureErrors[.codex] == nil)
    #expect(store.selectedAccounts[.codex] == liveAfterSwitch)
    #expect(selectionStore.load()[.codex] == savedAccount)
  }

  @Test func switchingAnIdlessSavedAccountSelectsTheSoleLiveLogin() async throws {
    // An id-less saved Codex account is matched by its token fingerprint, so
    // the post-switch live row hides the registry row and stands in for it.
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedAccount = try saveCodexSnapshot(registry, id: "codex:idless-uuid", accountID: nil)
    let liveAfterSwitch = liveCodexAccount(atWrittenSlot: home)
    let selectionStore = ProviderAccountSelectionStore(
      url: home.appendingPathComponent("ProviderAccounts.json")
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(accounts: [.codex: [savedAccount]]))
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    await store.reloadAccounts()

    discovery.update(StaticAccountDiscovery(
      accounts: [.codex: [liveAfterSwitch]],
      liveEquivalents: [savedAccount.id: liveAfterSwitch],
      capturedCopies: [liveAfterSwitch.id: savedAccount]
    ))
    await store.switchCLIAccount(to: savedAccount)

    #expect(store.captureErrors[.codex] == nil)
    #expect(store.selectedAccounts[.codex] == liveAfterSwitch)
    #expect(selectionStore.load()[.codex] == savedAccount)
  }

  @Test func switchDoesNotReportSuccessWhenRediscoveryCannotAnchorTheSavedAccount() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedAccount = try saveCodexSnapshot(registry, id: "codex:acct-saved")
    let unrelatedLive = liveCodexAccount(atWrittenSlot: home, identity: "acct-other")
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.codex: [savedAccount]]
    ))
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    await store.reloadAccounts()
    discovery.update(StaticAccountDiscovery(accounts: [.codex: [unrelatedLive]]))

    await store.switchCLIAccount(to: savedAccount)

    #expect(store
      .captureErrors[.codex] == "Switched the CLI login, but Quotari couldn't confirm it yet. Reload accounts.")
    #expect(store.selectedAccounts[.codex] != unrelatedLive)
  }
}

@MainActor
struct UsageStoreSwitchConcurrencyTests {
  @Test func switchKeepsTheGateClosedThroughRediscoveryAndFetchesOnceAfterward() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedAccount = try saveCodexSnapshot(registry, id: "codex:acct-saved")
    let liveAfterSwitch = liveCodexAccount(atWrittenSlot: home, identity: "acct-saved")
    let selectionStore = ProviderAccountSelectionStore(
      url: home.appendingPathComponent("ProviderAccounts.json")
    )
    let recorder = AccountRecorder()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: recorder)] }
    )
    let discovery = GatedSwitchDiscovery(
      beforeSwitch: StaticAccountDiscovery(accounts: [.codex: [savedAccount]]),
      afterSwitch: StaticAccountDiscovery(
        accounts: [.codex: [liveAfterSwitch]],
        liveEquivalents: [savedAccount.id: liveAfterSwitch],
        capturedCopies: [liveAfterSwitch.id: savedAccount]
      )
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    await store.reloadAccounts()

    let switching = Task { await store.switchCLIAccount(to: savedAccount) }
    await discovery.waitUntilSwitchReloadStarts()

    #expect(store.isSwitching)
    #expect(await recorder.accounts.isEmpty)
    store.beginRefresh()
    #expect(store.inFlightRefresh == nil)

    await discovery.resumeSwitchReload()
    await switching.value
    await store.selectionRefreshTasks[.codex]?.value

    #expect(!store.isSwitching)
    #expect(await recorder.accounts == [liveAfterSwitch])
    #expect(selectionStore.load()[.codex] == savedAccount)
  }

  @Test func switchAwaitsASupersededNoncooperativeSelectionRefresh() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedAccount = try saveCodexSnapshot(registry, id: "codex:acct-saved")
    let liveAfterSwitch = liveCodexAccount(atWrittenSlot: home, identity: "acct-saved")
    let strategy = AccountSwitchRaceStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [liveAfterSwitch]],
        liveEquivalents: [savedAccount.id: liveAfterSwitch],
        capturedCopies: [liveAfterSwitch.id: savedAccount]
      ),
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    let firstSelection = liveCodexAccount(identity: "acct-first", displayName: "First")
    let replacementSelection = liveCodexAccount(identity: "acct-second", displayName: "Second")
    store.selectAccount(firstSelection, for: .codex)
    await strategy.waitUntilFirstRequestStarts()

    // A cancelled noncooperative exchange must still drain before the switch writes the CLI slot.
    store.selectAccount(replacementSelection, for: .codex)
    let switching = Task { await store.switchCLIAccount(to: savedAccount) }
    #expect(await Self.waitUntilSwitchStarts(store))

    let authURL = home.appendingPathComponent(".codex/auth.json")
    #expect(!FileManager.default.fileExists(atPath: authURL.path))

    await strategy.resumeFirstRequest()
    await switching.value
    await store.selectionRefreshTasks[.codex]?.value

    #expect(FileManager.default.fileExists(atPath: authURL.path))
    #expect(await strategy.requestCount == 2)
  }

  @Test func aSecondConcurrentSwitchIsRejectedWithoutReplacingTheFirstTarget() async throws {
    let directory = try TemporaryDirectory()
    let home = directory.url
    let registry = CapturedAccountStore.inMemoryForTesting()
    let firstTarget = try saveCodexSnapshot(
      registry,
      id: "codex:acct-first-target",
      accountID: "acct-first-target"
    )
    let secondTarget = try saveCodexSnapshot(
      registry,
      id: "codex:acct-second-target",
      accountID: "acct-second-target"
    )
    let liveAfterSwitch = liveCodexAccount(atWrittenSlot: home, identity: "acct-first-target")
    let strategy = AccountSwitchRaceStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(
        accounts: [.codex: [liveAfterSwitch]],
        liveEquivalents: [firstTarget.id: liveAfterSwitch],
        capturedCopies: [liveAfterSwitch.id: firstTarget]
      ),
      accountSwitch: .isolatedForTesting(capturedAccounts: registry, home: home),
      startsAutomatically: false
    )
    store.selectAccount(liveCodexAccount(identity: "acct-current"), for: .codex)
    await strategy.waitUntilFirstRequestStarts()

    let firstSwitch = Task { await store.switchCLIAccount(to: firstTarget) }
    #expect(await Self.waitUntilSwitchStarts(store))
    await store.switchCLIAccount(to: secondTarget)

    #expect(store.captureErrors[.codex] == "Another account switch is already in progress.")
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/auth.json").path))

    await strategy.resumeFirstRequest()
    await firstSwitch.value
    await store.selectionRefreshTasks[.codex]?.value

    let slot = try JSONSerialization.jsonObject(
      with: Data(contentsOf: home.appendingPathComponent(".codex/auth.json"))
    ) as? [String: Any]
    #expect((slot?["tokens"] as? [String: Any])?["account_id"] as? String == "acct-first-target")
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
}

@MainActor
extension UsageStoreSwitchTests {
  @Test func refreshesAreSuppressedWhileSwitching() async {
    // The switch gate must block every credential-touching fetch entry point
    // so none rotates a slot mid-switch.
    let recorder = AccountRecorder()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [RecordingAccountStrategy(recorder: recorder)] }
    )
    let live = liveCodexAccount(identity: "acct-1")
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: EmptyCostEstimator(),
      accountDiscovery: StaticAccountDiscovery(accounts: [.codex: [live]]),
      startsAutomatically: false
    )
    await store.reloadAccounts()
    store.isSwitching = true

    store.beginAccountRediscovery()
    store.beginRefresh()
    await store.inFlightRefresh?.value
    await store.refreshAccountUsage(for: .codex, force: true)

    let fetches = await recorder.accounts.count
    #expect(store.inFlightAccountReload == nil)
    #expect(fetches == 0)

    store.isSwitching = false
    store.startQueuedAccountRediscoveryIfNeeded()
    await store.inFlightAccountReload?.value
  }
}
