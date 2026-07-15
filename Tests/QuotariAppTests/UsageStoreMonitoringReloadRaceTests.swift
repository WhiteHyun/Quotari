import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringReloadRaceTests {
  @Test func startupRefreshWaitsForNewerQueuedAccountReload() async throws {
    let replacement = ProviderAccount(
      provider: .codex,
      displayName: "Replacement",
      detail: "Default",
      credentialSource: MonitoringFixture.personal.credentialSource,
      credentialIdentity: "replacement"
    )
    let discovery = SequencedMonitoringDiscovery(
      results: [[MonitoringFixture.personal], [replacement]]
    )
    let fixture = try MonitoringFixture(
      monitored: [.codex: [MonitoringFixture.personal]],
      accountDiscovery: discovery
    )
    defer { fixture.remove() }

    let startupReload = Task { await fixture.store.reloadAccounts() }
    await discovery.waitUntilRequestStarts(1)
    fixture.store.beginAccountRediscovery()
    await discovery.release(1)
    await startupReload.value
    await discovery.waitUntilRequestStarts(2)

    let completion = MonitoringPreparationCompletion()
    let preparation = Task {
      let result = await fixture.store.prepareReconciledAccountsForRefresh(
        reusesLatestAccountReload: true
      )
      await completion.finish()
      return result
    }
    for _ in 0 ..< 10 {
      await Task.yield()
    }

    let finishedBeforeLatestReload = await completion.isFinished
    #expect(!finishedBeforeLatestReload)
    await discovery.release(2)
    #expect(await preparation.value)
    #expect(fixture.store.accounts[.codex] == [replacement])
  }

  @Test func monitoringToggleDuringLaterProviderReloadIsPreserved() async throws {
    let codex = ProviderAccount(
      provider: .codex,
      displayName: "Codex",
      detail: "Default",
      credentialSource: .codexAuthFile(path: "/tmp/monitor-race-codex/auth.json"),
      credentialIdentity: "codex"
    )
    let claude = ProviderAccount(
      provider: .claude,
      displayName: "Claude",
      detail: "Keychain",
      credentialSource: .claudeKeychain(service: "monitor-race-claude"),
      credentialIdentity: "claude"
    )
    let discovery = MonitoringReloadGate(codex: codex, claude: claude)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-monitoring-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.appendingPathComponent("ProviderAccounts.json")
    )
    let monitoringStore = ProviderAccountMonitoringStore(
      url: directory.appendingPathComponent("MonitoredProviderAccounts.json")
    )
    try monitoringStore.save([.codex: [codex], .claude: [claude]])
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor(for: .codex), descriptor(for: .claude)],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountMonitoringStore: monitoringStore,
      startsAutomatically: false
    )

    let reload = Task { await store.reloadAccounts() }
    await discovery.waitUntilClaudeRequestStarts()
    store.setMonitoring(false, for: codex)
    await discovery.resumeClaudeRequest()
    await reload.value

    #expect(store.monitoredAccounts[.codex] == [])
    #expect(monitoringStore.load()[.codex] == [])
  }

  private func descriptor(for provider: UsageProvider) -> ProviderDescriptor {
    ProviderDescriptor(
      id: provider,
      metadata: ProviderMetadata(
        displayName: provider.rawValue,
        accent: .init(0, 0.6, 0.5),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [MonitoringReloadStrategy()] }
    )
  }
}

private actor MonitoringPreparationCompletion {
  private(set) var isFinished = false

  func finish() {
    isFinished = true
  }
}

private actor SequencedMonitoringDiscovery: ProviderAccountDiscovering {
  private let results: [[ProviderAccount]]
  private var requestCount = 0
  private var releasedRequests = Set<Int>()
  private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
  private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

  init(results: [[ProviderAccount]]) {
    self.results = results
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    requestCount += 1
    let request = requestCount
    let readyWaiters = startWaiters.keys.filter { $0 <= request }
    for key in readyWaiters {
      startWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
    }
    if !releasedRequests.contains(request) {
      await withCheckedContinuation { releaseWaiters[request, default: []].append($0) }
    }
    return results[min(request - 1, results.count - 1)]
  }

  func waitUntilRequestStarts(_ request: Int) async {
    guard requestCount < request else { return }
    await withCheckedContinuation { startWaiters[request, default: []].append($0) }
  }

  func release(_ request: Int) {
    releasedRequests.insert(request)
    releaseWaiters.removeValue(forKey: request)?.forEach { $0.resume() }
  }
}

private actor MonitoringReloadGate: ProviderAccountDiscovering {
  let codex: ProviderAccount
  let claude: ProviderAccount
  private var claudeRequestStarted = false
  private var claudeRequestReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(codex: ProviderAccount, claude: ProviderAccount) {
    self.codex = codex
    self.claude = claude
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    guard provider == .claude else { return [codex] }
    claudeRequestStarted = true
    startWaiters.forEach { $0.resume() }
    startWaiters.removeAll()
    if !claudeRequestReleased {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
    return [claude]
  }

  func waitUntilClaudeRequestStarts() async {
    guard !claudeRequestStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resumeClaudeRequest() {
    claudeRequestReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}

private struct MonitoringReloadStrategy: ProviderFetchStrategy {
  let id = "monitoring-reload"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        primary: RateWindow(kind: .session, usedPercent: 0),
        updatedAt: context.now
      ),
      sourceLabel: "Test",
      credentialScopeID: context.account?.credentialScopeID
    )
  }
}
