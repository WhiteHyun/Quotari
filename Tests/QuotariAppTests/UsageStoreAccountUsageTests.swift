import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAccountUsageTests {
  @Test func loadsEveryAccountOnceAcrossConcurrentRequests() async throws {
    let context = try Self.makeContext()
    defer { context.directory.remove() }
    await context.store.reloadAccounts()

    async let first: Void = context.store.refreshAccountUsage(for: .codex, force: true)
    async let second: Void = context.store.refreshAccountUsage(for: .codex, force: true)
    _ = await (first, second)

    #expect(await context.recorder.requestedAccountNames.sorted() == ["Personal", "Work"])
    #expect(context.store.accountUsage(for: context.personal)?.snapshot?.primary?.usedPercent == 20)
    #expect(context.store.accountUsage(for: context.work)?.snapshot?.primary?.usedPercent == 70)
    #expect(context.store.selectedAccounts[.codex] == nil)
  }

  @Test func selectingLoadedAccountUpdatesDashboardAndPersistsSelection() async throws {
    let context = try Self.makeContext()
    defer { context.directory.remove() }
    await context.store.reloadAccounts()
    await context.store.refreshAccountUsage(for: .codex, force: true)

    context.store.selectAccount(context.work, for: .codex)

    #expect(context.store.selectedAccounts[.codex] == context.work)
    #expect(context.store.snapshots[.codex]?.account == "Work")
    #expect(context.store.snapshots[.codex]?.primary?.usedPercent == 70)
    #expect(context.selectionStore.load()[.codex] == context.work)
  }

  @Test func expiredCachedUsageIsHiddenFromPicker() throws {
    let context = try Self.makeContext()
    defer { context.directory.remove() }
    let stale = UsageSnapshot(
      provider: .codex,
      plan: "Team",
      primary: RateWindow(kind: .session, usedPercent: 70),
      secondary: nil,
      updatedAt: Date(timeIntervalSinceNow: -UsageStore.cachedAccountUsageLifetime - 1)
    )
    context.store.accountUsage = [.codex: [context.work.id: ProviderAccountUsage(snapshot: stale)]]

    #expect(context.store.accountUsage(for: context.work) == nil)
  }

  private static func makeContext() throws -> TestContext {
    let directory = try AccountUsageDirectory()
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("ProviderAccounts.json")
    )
    let personal = account(name: "Personal", path: "/tmp/personal/auth.json")
    let work = account(name: "Work", path: "/tmp/work/auth.json")
    let recorder = AccountUsageRecorder()
    let strategy = AccountUsageStrategy(recorder: recorder)
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(displayName: "Codex", accent: .init(0, 0.6, 0.5), supportsWeekly: true),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      costEstimator: NoAccountUsageCostEstimator(),
      accountDiscovery: AccountUsageDiscovery(accounts: [.codex: [personal, work]]),
      accountSelectionStore: selectionStore,
      startsAutomatically: false
    )
    return TestContext(
      store: store,
      recorder: recorder,
      selectionStore: selectionStore,
      personal: personal,
      work: work,
      directory: directory
    )
  }

  private static func account(name: String, path: String) -> ProviderAccount {
    ProviderAccount(
      provider: .codex,
      displayName: name,
      detail: name == "Personal" ? "Pro 20x" : "Team",
      credentialSource: .codexAuthFile(path: path),
      credentialIdentity: name
    )
  }

  private struct TestContext {
    let store: UsageStore
    let recorder: AccountUsageRecorder
    let selectionStore: ProviderAccountSelectionStore
    let personal: ProviderAccount
    let work: ProviderAccount
    let directory: AccountUsageDirectory
  }
}

private struct AccountUsageDiscovery: ProviderAccountDiscovering {
  let accounts: [UsageProvider: [ProviderAccount]]

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    accounts[provider] ?? []
  }
}

private struct NoAccountUsageCostEstimator: UsageCostEstimating {
  func costSummary(provider: UsageProvider, now: Date, historyDays: Int) async -> CostSummary? {
    nil
  }
}

private actor AccountUsageRecorder {
  private(set) var requestedAccountNames: [String] = []

  func record(_ account: ProviderAccount?) {
    requestedAccountNames.append(account?.displayName ?? "Automatic")
  }
}

private struct AccountUsageStrategy: ProviderFetchStrategy {
  let recorder: AccountUsageRecorder
  let id = "account-usage"
  let kind = ProviderFetchKind.api

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    await recorder.record(context.account)
    try await Task.sleep(for: .milliseconds(20))
    let isWork = context.account?.displayName == "Work"
    return ProviderFetchResult(
      usage: UsageSnapshot(
        provider: context.provider,
        plan: isWork ? "Team" : "Pro 20x",
        primary: RateWindow(kind: .session, usedPercent: isWork ? 70 : 20),
        secondary: RateWindow(kind: .weekly, usedPercent: isWork ? 35 : 10),
        updatedAt: context.now
      ),
      sourceLabel: "Stub"
    )
  }
}

private final class AccountUsageDirectory: Sendable {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("quotari-account-usage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}
