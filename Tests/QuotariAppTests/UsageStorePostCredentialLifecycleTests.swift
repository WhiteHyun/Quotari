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
      .postSwitchRefreshCompleted,
    ])
    #expect(recorder.events.allSatisfy { $0.accountID == "opaque:\(scheduledAccount.id)" })
  }
}
