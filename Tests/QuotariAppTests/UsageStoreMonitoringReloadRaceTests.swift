import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreMonitoringReloadRaceTests {
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
