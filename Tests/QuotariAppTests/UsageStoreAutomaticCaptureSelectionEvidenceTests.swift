import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct CaptureSelectionEvidenceTests {
  // swiftlint:disable:next function_body_length
  @Test func failedRefreshCaptureKeepsSelectionOnTheExistingSavedAccount() async throws {
    let directory = try TemporaryDirectory()
    let payload = AutomaticCapturePayloadBox(
      claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let saved = CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "saved-access", refreshToken: "saved-refresh")
    )
    try registry.save(saved)
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let selected = try #require(await discovery.accounts(for: .claude).first {
      !$0.credentialSource.isCaptured
    })
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("selection.json")
    )
    try selectionStore.save([.claude: selected])
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in
          let replacement = claudePayload(accessToken: "access-b", refreshToken: "refresh-b")
          payload.value = replacement
          return replacement
        }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "access-a": ClaudeProfile(accountID: "same-account", email: "same@example.com"),
        "saved-access": ClaudeProfile(accountID: "same-account", email: "same@example.com"),
      ]),
      claudeCredentialLoader: { source in
        selectionEvidenceCredentials(source: source, payload: payload, registry: registry)
      },
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(store.selectedAccounts[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(store.reconciledSelectionOrigins[.claude] == nil)
    #expect(selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(store.captureErrors[.claude]?.contains("changed") == true)
  }

  // swiftlint:disable:next function_body_length
  @Test func failedProfileLookupStillAdvancesAQuotariCredentialRotation() async throws {
    let directory = try TemporaryDirectory()
    let payload = AutomaticCapturePayloadBox(
      claudePayload(
        accessToken: "access-a",
        refreshToken: "refresh-a",
        expiresAt: Date(timeIntervalSince1970: 0)
      )
    )
    let rotated = claudePayload(
      accessToken: "access-b",
      refreshToken: "refresh-b",
      expiresAt: Date().addingTimeInterval(3600)
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:other",
      provider: .claude,
      displayName: "Other Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "other-access", refreshToken: "other-refresh")
    ))
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let selected = try #require(await discovery.accounts(for: .claude).first {
      !$0.credentialSource.isCaptured
    })
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("selection.json")
    )
    try selectionStore.save([.claude: selected])
    let strategy = ImmediateClaudeRotationStrategy(payload: payload, rotatedPayload: rotated)
    let descriptor = ProviderDescriptor(
      id: .claude,
      metadata: ProviderMetadata(
        displayName: "Claude",
        accent: .init(0.8, 0.5, 0.2),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in payload.value }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "other-access": ClaudeProfile(accountID: "other", email: "other@example.com"),
      ]),
      claudeCredentialLoader: { source in
        selectionEvidenceCredentials(source: source, payload: payload, registry: registry)
      },
      startsAutomatically: false
    )

    await store.reloadAccounts()

    let live = try #require(store.accounts[.claude]?.first { !$0.credentialSource.isCaptured })
    #expect(live.credentialScopeID != selected.credentialScopeID)
    #expect(store.selectedAccounts[.claude] == live)
    #expect(store.reconciledSelectionOrigins[.claude] == nil)
    #expect(selectionStore.load()[.claude] == live)
    #expect(registry.load().map(\.id) == ["claude:other"])
  }

  @Test func profileCopyRevalidatesTheLiveCredentialAfterSuspension() async throws {
    let directory = try TemporaryDirectory()
    let payload = AutomaticCapturePayloadBox(
      claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let saved = CapturedAccount(
      id: "claude:saved",
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
    )
    try registry.save(saved)
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let live = try #require(await discovery.accounts(for: .claude).first {
      !$0.credentialSource.isCaptured
    })
    let reader = BlockingSavedClaudeCredentialReader(payload: payload, registry: registry)
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "access-a": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
        "access-b": ClaudeProfile(accountID: "account-b", email: "b@example.com"),
      ]),
      claudeCredentialLoader: { reader.load($0) },
      startsAutomatically: false
    )

    await store.reloadAccounts()
    await reader.waitUntilSavedReadStarts()
    payload.value = claudePayload(accessToken: "access-b", refreshToken: "refresh-b")
    reader.resumeSavedRead()

    #expect(await waitUntilSelectionEvidence {
      store.claudeProfiles[live.id]?.accountID == "account-b"
        && store.profileFetchTasks.isEmpty
    })
    #expect(store.claudeProfiles[saved.providerAccount.id] == nil)
  }
}

private actor ImmediateClaudeRotationStrategy: ProviderFetchStrategy {
  nonisolated let id = "immediate-claude-rotation"
  nonisolated let kind = ProviderFetchKind.oauth
  private let payload: AutomaticCapturePayloadBox
  private let rotatedPayload: Data

  init(payload: AutomaticCapturePayloadBox, rotatedPayload: Data) {
    self.payload = payload
    self.rotatedPayload = rotatedPayload
  }

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    let sourceScopeID = context.account?.credentialScopeID
    payload.value = rotatedPayload
    let credentials = try ClaudeCredentialsStore.parse(rotatedPayload)
    let target = ProviderAccount(
      provider: .claude,
      displayName: context.account?.displayName ?? "Claude Code",
      detail: context.account?.detail,
      credentialSource: context.account?.credentialSource ?? .claudeKeychain(
        service: ClaudeCredentialsStore.keychainService
      ),
      credentialIdentity: credentials.accessToken
    )
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: .claude, updatedAt: context.now),
      sourceLabel: "Rotated",
      credentialScopeID: target.credentialScopeID,
      credentialTransitionSourceScopeIDs: Set([sourceScopeID].compactMap(\.self))
    )
  }
}

private final class BlockingSavedClaudeCredentialReader: @unchecked Sendable {
  private let payload: AutomaticCapturePayloadBox
  private let registry: CapturedAccountStore
  private let signal = SavedCredentialReadSignal()
  private let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var blocksNextSavedRead = true

  init(payload: AutomaticCapturePayloadBox, registry: CapturedAccountStore) {
    self.payload = payload
    self.registry = registry
  }

  func load(_ source: ProviderCredentialSource) -> ClaudeCredentials? {
    switch source {
    case .claudeKeychain:
      return try? ClaudeCredentialsStore.parse(payload.value)
    case let .quotariRegistry(id):
      let blocks = lock.withLock {
        defer { blocksNextSavedRead = false }
        return blocksNextSavedRead
      }
      if blocks {
        Task { await signal.markStarted() }
        release.wait()
      }
      return registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
    case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
      return nil
    }
  }

  func waitUntilSavedReadStarts() async {
    await signal.waitUntilStarted()
  }

  func resumeSavedRead() {
    release.signal()
  }
}

private actor SavedCredentialReadSignal {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private func selectionEvidenceCredentials(
  source: ProviderCredentialSource,
  payload: AutomaticCapturePayloadBox,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  switch source {
  case .claudeKeychain:
    try? ClaudeCredentialsStore.parse(payload.value)
  case let .quotariRegistry(id):
    registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
  case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
    nil
  }
}

@MainActor
private func waitUntilSelectionEvidence(
  attempts: Int = 200,
  _ condition: () -> Bool
) async -> Bool {
  for _ in 0 ..< attempts {
    if condition() {
      return true
    }
    await Task.yield()
  }
  return condition()
}
