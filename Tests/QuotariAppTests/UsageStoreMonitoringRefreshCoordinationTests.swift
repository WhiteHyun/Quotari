import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct MonitoringRefreshCoordinationTests {
  @Test func enablingMonitoringRefreshesOnlyTheNewAccount() async throws {
    let fixture = try MonitoringFixture(monitored: [.codex: [MonitoringFixture.personal]])
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    fixture.store.setMonitoring(true, for: MonitoringFixture.work)
    await fixture.store.refreshAccountUsage(for: MonitoringFixture.work)

    #expect(await fixture.recorder.names == ["Work"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal) == nil)
    #expect(fixture.store.accountUsage(for: MonitoringFixture.work)?.snapshot != nil)
  }

  @Test func savedMonitoringRequestResolvesItsLiveManagedAccount() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let fixture = try MonitoringFixture(
      accounts: [MonitoringFixture.personal],
      capturedCopies: [MonitoringFixture.personal.id: saved],
      monitored: [.codex: [saved]]
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    #expect(fixture.store.monitoredAccounts[.codex] == [MonitoringFixture.personal])

    await fixture.store.refreshAccountUsage(for: saved)

    #expect(await fixture.recorder.names == ["Personal"])
    #expect(fixture.store.accountUsage(for: MonitoringFixture.personal)?.snapshot != nil)
  }

  @Test func forcedRefreshUpgradesAnInFlightNonForcedRequest() async throws {
    let gate = MonitoringUsageGate()
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.work]],
      strategyGate: gate
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()

    let first = Task { await fixture.store.refreshAccountUsage(for: MonitoringFixture.work) }
    await gate.waitUntilFirstRequestStarts()
    let forced = Task { await fixture.store.refreshAccountUsage(for: MonitoringFixture.work, force: true) }
    await gate.resumeFirstRequest()
    await first.value
    await forced.value

    #expect(await fixture.recorder.names == ["Work", "Work"])
  }

  @Test func accountRefreshResolvesRotatedScopeAfterCaptureReload() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Personal",
      detail: "Default",
      credentialSource: MonitoringFixture.personal.credentialSource,
      credentialIdentity: "rotated-personal"
    )
    let discovery = CaptureReloadDiscovery(
      account: MonitoringFixture.personal,
      capturedCopy: saved
    )
    let fixture = try MonitoringFixture(
      accounts: [],
      monitored: [.codex: [saved]],
      accountDiscovery: discovery
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    let staleAccount = try #require(fixture.store.monitoredAccounts[.codex]?.first)

    await discovery.prepareReplacement(account: replacement, capturedCopy: saved)
    let reload = Task { await fixture.store.reloadAccounts() }
    await discovery.waitUntilReplacementRequestStarts()
    fixture.store.automaticallyCapturingProviders.insert(.codex)
    let refresh = Task { await fixture.store.refreshAccountUsage(for: staleAccount) }
    await discovery.releaseReplacementRequest()
    await reload.value
    await refresh.value
    fixture.store.automaticallyCapturingProviders.remove(.codex)

    #expect(await fixture.recorder.names == ["Personal"])
    #expect(fixture.store.accountUsage(for: replacement)?.snapshot != nil)
  }

  @Test func queuedAccountRefreshReResolvesScopeAfterReload() async throws {
    let saved = ProviderAccount(
      provider: .codex,
      displayName: "Saved Personal",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: "codex:personal")
    )
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement",
      detail: "Default",
      credentialSource: MonitoringFixture.personal.credentialSource,
      credentialIdentity: "replacement"
    )
    let discovery = MutableAccountDiscovery(StaticAccountDiscovery(
      accounts: [.codex: [MonitoringFixture.personal]],
      capturedCopies: [MonitoringFixture.personal.id: saved]
    ))
    let gate = MonitoringUsageGate()
    let fixture = try MonitoringFixture(
      monitored: [.codex: [saved]],
      accountDiscovery: discovery,
      strategyGate: gate
    )
    defer { fixture.remove() }
    await fixture.store.reloadAccounts()
    let original = try #require(fixture.store.monitoredAccounts[.codex]?.first)

    let first = Task { await fixture.store.refreshAccountUsage(for: .codex, force: true) }
    await gate.waitUntilFirstRequestStarts()
    let queued = Task { await fixture.store.refreshAccountUsage(for: original) }
    for _ in 0 ..< 10 {
      await Task.yield()
    }
    discovery.update(StaticAccountDiscovery(
      accounts: [.codex: [replacement]],
      capturedCopies: [replacement.id: saved]
    ))
    await fixture.store.reloadAccounts()
    await gate.resumeFirstRequest()
    await first.value
    await queued.value

    #expect(await fixture.recorder.names == ["Personal", "Replacement"])
    #expect(fixture.store.accountUsage(for: replacement)?.snapshot != nil)
  }
}

private actor CaptureReloadDiscovery: ProviderAccountDiscovering {
  private var account: ProviderAccount
  private var capturedCopy: ProviderAccount
  private var blocksNextRequest = false
  private var replacementRequestStarted = false
  private var replacementRequestReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(account: ProviderAccount, capturedCopy: ProviderAccount) {
    self.account = account
    self.capturedCopy = capturedCopy
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    if blocksNextRequest {
      replacementRequestStarted = true
      startWaiters.forEach { $0.resume() }
      startWaiters.removeAll()
      if !replacementRequestReleased {
        await withCheckedContinuation { releaseWaiters.append($0) }
      }
      blocksNextRequest = false
    }
    return [account]
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    [account.id: capturedCopy]
  }

  func prepareReplacement(account: ProviderAccount, capturedCopy: ProviderAccount) {
    self.account = account
    self.capturedCopy = capturedCopy
    blocksNextRequest = true
    replacementRequestStarted = false
    replacementRequestReleased = false
  }

  func waitUntilReplacementRequestStarts() async {
    guard !replacementRequestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func releaseReplacementRequest() {
    replacementRequestReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
