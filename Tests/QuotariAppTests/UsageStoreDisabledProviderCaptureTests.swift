import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreDisabledProviderCaptureTests {
  @Test func scanDoesNotCaptureAccountsForDisabledProvider() async throws {
    let directory = try TemporaryDirectory()
    let payload = Data(
      #"{"claudeAiOauth":{"accessToken":"claude-access","refreshToken":"claude-refresh"}}"#.utf8
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in payload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )
    store.setProviderEnabled(.claude, enabled: false)

    await store.reloadAccounts()

    #expect(registry.load().isEmpty)
    #expect(store.accounts[.claude]?.isEmpty == false)
    #expect(store.capturedEquivalents.isEmpty)
  }

  @Test func disablingProviderStopsASecondAutomaticCapturePass() async throws {
    let context = try makeContext(accountID: "first-account", email: "first@example.com")
    let discovery = SecondPassGatedDiscovery(base: context.discovery)
    let store = UsageStore.isolatedForTesting(
      providers: [codexDescriptor()],
      accountDiscovery: discovery,
      accountSelectionStore: context.selectionStore,
      accountCapture: context.capture,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    let reload = Task { await store.reloadAccounts() }
    await discovery.waitUntilSecondPassStarts()
    store.setProviderEnabled(.codex, enabled: false)
    try writeCodexCredentials(
      to: context.authURL,
      accountID: "second-account",
      email: "second@example.com"
    )
    await discovery.resumeSecondPass()
    await reload.value

    #expect(context.registry.load().map(\.id) == ["codex:first-account"])
  }
}

private actor SecondPassGatedDiscovery: ProviderAccountDiscovering {
  private let base: any ProviderAccountDiscovering
  private var accountRequests = 0
  private var secondPassStarted = false
  private var secondPassReleased = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  init(base: any ProviderAccountDiscovering) {
    self.base = base
  }

  func accounts(for provider: UsageProvider) async -> [ProviderAccount] {
    accountRequests += 1
    if accountRequests == 2 {
      secondPassStarted = true
      startWaiters.forEach { $0.resume() }
      startWaiters.removeAll()
      if !secondPassReleased {
        await withCheckedContinuation { releaseWaiters.append($0) }
      }
    }
    return await base.accounts(for: provider)
  }

  func liveAccount(
    equivalentTo account: ProviderAccount,
    among accounts: [ProviderAccount]
  ) async -> ProviderAccount? {
    await base.liveAccount(equivalentTo: account, among: accounts)
  }

  func capturedCopies(among accounts: [ProviderAccount]) async -> [String: ProviderAccount] {
    await base.capturedCopies(among: accounts)
  }

  func waitUntilSecondPassStarts() async {
    guard !secondPassStarted else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func resumeSecondPass() {
    secondPassReleased = true
    releaseWaiters.forEach { $0.resume() }
    releaseWaiters.removeAll()
  }
}
