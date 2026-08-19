import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct PostCredentialLifecycleTests {
  @Test func delayedRefreshRetainsTheScheduledAccountForTerminalEvents() async {
    let strategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let recorder = AppCredentialLifecycleEventRecorder()
    let scheduledAccount = ProviderAccount(
      provider: .claude,
      displayName: "Scheduled",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:scheduled")
    )
    let replacementAccount = ProviderAccount(
      provider: .claude,
      displayName: "Replacement",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:replacement")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(strategy: strategy)],
      postCredentialRefreshSleep: delay.sleep,
      credentialLifecycleLogger: recorder.logger,
      startsAutomatically: false
    )
    store.reconciledSelectionOrigins[.claude] = scheduledAccount

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts()
    let delayedTask = store.delayedCredentialRefreshTasks[.claude]?.task
    store.reconciledSelectionOrigins[.claude] = replacementAccount
    await strategy.resume()
    await delayedTask?.value

    #expect(recorder.events.map(\.kind) == [
      .postSwitchRefreshScheduled,
      .postSwitchRefreshStarted,
      .validationStarted,
      .validationSucceeded,
      .postSwitchRefreshCompleted,
    ])
    #expect(recorder.events.allSatisfy { $0.accountID == "opaque:\(scheduledAccount.id)" })
  }

  @Test func cancellingAStartedDelayedRefreshRecordsItsTerminalEvent() async {
    let strategy = GatedPostCredentialUsageStrategy()
    let delay = PostCredentialRefreshGate()
    let recorder = AppCredentialLifecycleEventRecorder()
    let scheduledAccount = ProviderAccount(
      provider: .claude,
      displayName: "Scheduled",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "claude:scheduled")
    )
    let store = UsageStore.isolatedForTesting(
      providers: [postCredentialDescriptor(strategy: strategy)],
      postCredentialRefreshSleep: delay.sleep,
      credentialLifecycleLogger: recorder.logger,
      startsAutomatically: false
    )
    store.reconciledSelectionOrigins[.claude] = scheduledAccount

    store.enqueuePostCredentialRefresh(for: .claude)
    await delay.waitUntilRequested()
    await delay.resumeAll()
    await strategy.waitUntilRequestStarts()
    let delayedTask = store.delayedCredentialRefreshTasks[.claude]?.task
    store.cancelDelayedCredentialRefresh(for: .claude)
    await strategy.resume()
    await delayedTask?.value

    let postSwitchEvents = recorder.events.filter {
      $0.kind == .postSwitchRefreshScheduled
        || $0.kind == .postSwitchRefreshStarted
        || $0.kind == .postSwitchRefreshCompleted
        || $0.kind == .postSwitchRefreshCancelled
    }
    #expect(postSwitchEvents.map(\.kind) == [
      .postSwitchRefreshScheduled,
      .postSwitchRefreshStarted,
      .postSwitchRefreshCancelled,
    ])
    #expect(postSwitchEvents.last?.failure == .cancelled)
    #expect(postSwitchEvents.allSatisfy { $0.accountID == "opaque:\(scheduledAccount.id)" })
  }

  @Test func dashboardFetchRecordsValidationForTheSelectedSavedAccount() async throws {
    let strategy = GatedPostCredentialUsageStrategy()
    let recorder = AppCredentialLifecycleEventRecorder()
    let descriptor = postCredentialDescriptor(provider: .codex, strategy: strategy)
    let liveAccount = liveCodexAccount(identity: "acct-live")
    let savedAccount = savedCodexAccount()
    let selectionStore = ProviderAccountSelectionStore.temporaryForTesting()
    try selectionStore.save([.codex: liveAccount])
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountSelectionStore: selectionStore,
      credentialLifecycleLogger: recorder.logger,
      startsAutomatically: false
    )
    store.capturedEquivalents[liveAccount.id] = savedAccount

    let fetch = Task {
      await store.coordinatedProviderFetch(
        descriptor: descriptor,
        now: Date(timeIntervalSince1970: 1_783_478_400),
        interaction: .background
      )
    }
    await strategy.waitUntilRequestStarts()
    await strategy.resume()
    _ = await fetch.value

    #expect(recorder.events.map(\.kind) == [
      .validationStarted,
      .validationSucceeded,
    ])
    #expect(recorder.events.map(\.source) == [.codexFile, .codexFile])
    #expect(recorder.events.allSatisfy { $0.accountID == "opaque:\(savedAccount.id)" })
  }
}
