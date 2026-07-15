import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureReviewTests {
  @Test func firstClaudeScanDeduplicatesRotatedKeychainAndFileCopies() async throws {
    let fixture = try await makeDuplicateClaudeCaptureFixture()

    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.load().first)
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    #expect(fixture.registry.load().count == 1)
    #expect(credentials.accessToken == "keychain-access")
    #expect(credentials.refreshToken == "keychain-refresh")
    #expect(fixture.store.accounts[.claude]?.count == 1)
    #expect(fixture.store.accounts[.claude]?.first?.credentialSource == .claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    ))
    #expect(fixture.store.captureErrors[.claude] == nil)
    #expect(fixture.store.selectedAccounts[.claude]?.credentialSource == .claudeKeychain(
      service: ClaudeCredentialsStore.keychainService
    ))
    #expect(fixture.store.reconciledSelectionOrigins[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(fixture.selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
  }

  @Test func scanAnchorsASelectedClaudeLoginToItsCapturedAccount() async throws {
    let directory = try TemporaryDirectory()
    let payload = claudePayload(accessToken: "claude-access", refreshToken: "claude-refresh")
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload },
      capturedAccounts: registry
    )
    let live = try #require(await discovery.accounts(for: .claude).first)
    let selectionStore = ProviderAccountSelectionStore(
      url: directory.url.appendingPathComponent("selection.json")
    )
    try selectionStore.save([.claude: live])
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountSelectionStore: selectionStore,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in payload }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    await store.reloadAccounts()

    let saved = try #require(registry.load().first)
    #expect(store.selectedAccounts[.claude] == live)
    #expect(store.reconciledSelectionOrigins[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
    #expect(selectionStore.load()[.claude]?.credentialSource == .quotariRegistry(id: saved.id))
  }

  @Test func externalClaudeRotationRefreshesTheExistingCapturedAccount() async throws {
    let fixture = try makeRotatingClaudeCaptureFixture()
    await fixture.store.reloadAccounts()
    let original = try #require(fixture.registry.load().first)
    let savedID = ProviderAccount.id(
      provider: .claude,
      source: .quotariRegistry(id: original.id)
    )
    #expect(await waitUntil { fixture.store.claudeProfiles[savedID]?.accountID == "claude-account" })

    fixture.payload.value = claudePayload(
      accessToken: "access-b",
      refreshToken: "refresh-b",
      expiresAt: Date(timeIntervalSince1970: 2_000_003_600)
    )
    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.load().first)
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    #expect(fixture.registry.load().count == 1)
    #expect(saved.id == original.id)
    #expect(credentials.accessToken == "access-b")
    #expect(credentials.refreshToken == "refresh-b")
  }

  @Test func cancelledSelectionFetchDoesNotStartAfterCaptureFinishes() async throws {
    let context = try makeContext(accountID: "acct-a", email: "a@example.com")
    let discovery = GatedPostCaptureDiscovery(context.discovery)
    let strategy = AutomaticCaptureCountingStrategy()
    let descriptor = countingCodexDescriptor(strategy: strategy)
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      accountDiscovery: discovery,
      accountCapture: context.capture,
      automaticallyCapturesDiscoveredAccounts: true,
      startsAutomatically: false
    )

    let reload = Task { await store.reloadAccounts() }
    await discovery.waitUntilVerificationReadStarts()
    let cancelled = Task {
      await store.selectionProviderFetch(descriptor: descriptor, now: Date())
    }
    cancelled.cancel()
    let replacement = Task {
      await store.selectionProviderFetch(descriptor: descriptor, now: Date())
    }
    await discovery.resumeVerificationRead()
    await reload.value
    _ = await cancelled.value
    _ = await replacement.value

    #expect(await strategy.requestCount == 1)
  }

  @Test func replacedClaudeSlotDoesNotCopyItsProfileToThePreviousSavedAccount() async throws {
    let directory = try TemporaryDirectory()
    let payload = AutomaticCapturePayloadBox(
      claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
    )
    let registry = CapturedAccountStore.inMemoryForTesting()
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let capture = AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    )
    let live = try #require(await discovery.accounts(for: .claude).first)
    let saved = try capture.capture(live, now: Date())
    let savedID = ProviderAccount.id(
      provider: .claude,
      source: .quotariRegistry(id: saved.id)
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: capture,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "access-a": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
        "access-b": ClaudeProfile(accountID: "account-b", email: "b@example.com"),
      ]),
      profileStore: ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json")),
      claudeCredentialLoader: { source in
        claudeCredentials(source: source, payload: payload, registry: registry)
      },
      startsAutomatically: false
    )
    await store.reloadAccounts()
    #expect(await waitUntil {
      store.claudeProfiles[live.id]?.accountID == "account-a"
        && store.claudeProfiles[savedID]?.accountID == "account-a"
        && store.profileFetchTasks.isEmpty
    })

    payload.value = claudePayload(accessToken: "access-b", refreshToken: "refresh-b")
    store.profileFetchAttempts[live.id] = nil
    store.refreshClaudeProfiles()
    #expect(await waitUntil {
      store.claudeProfiles[live.id]?.accountID == "account-b"
        && store.profileFetchTasks.isEmpty
    })

    #expect(store.claudeProfiles[savedID]?.accountID == "account-a")
    #expect(store.claudeProfiles[savedID]?.email == "a@example.com")
  }

  @Test func disablingProviderCancelsSelectionProviderFetch() async {
    let strategy = CancellableProviderFetchStrategy()
    let descriptor = ProviderDescriptor(
      id: .codex,
      metadata: ProviderMetadata(
        displayName: "Codex",
        accent: .init(0.2, 0.4, 0.6),
        supportsWeekly: true
      ),
      pipeline: ProviderFetchPipeline { _ in [strategy] }
    )
    let store = UsageStore.isolatedForTesting(
      providers: [descriptor],
      startsAutomatically: false
    )
    let fetch = Task {
      await store.selectionProviderFetch(descriptor: descriptor, now: Date())
    }
    await strategy.waitUntilRequestStarts()

    store.setProviderEnabled(.codex, enabled: false)
    _ = await fetch.value

    #expect(await strategy.wasCancelled)
    #expect(store.selectionProviderFetchTasks[.codex] == nil)
  }

  @Test func changedClaudeSlotCannotReceiveThePreviousFetchedProfile() async throws {
    let directory = try TemporaryDirectory()
    let initial = claudePayload(accessToken: "access-a", refreshToken: "refresh-a")
    let replacement = claudePayload(accessToken: "access-b", refreshToken: "refresh-b")
    let payload = AutomaticCapturePayloadBox(initial)
    let registry = CapturedAccountStore.inMemoryForTesting()
    try registry.save(CapturedAccount(
      id: "claude:existing",
      provider: .claude,
      displayName: "Existing Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 0),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(accessToken: "access-existing", refreshToken: "refresh-existing")
    ))
    let discovery = ProviderAccountDiscovery(
      environment: [:],
      home: directory.url,
      keychainData: { payload.value },
      capturedAccounts: registry
    )
    let store = UsageStore.isolatedForTesting(
      providers: [claudeDescriptorForAutomaticCapture()],
      accountDiscovery: discovery,
      accountCapture: AccountCaptureService(
        capturedAccounts: registry,
        claudeKeychainRead: { _ in
          payload.value = replacement
          return replacement
        }
      ),
      automaticallyCapturesDiscoveredAccounts: true,
      profileFetcher: TokenClaudeProfileFetcher(profiles: [
        "access-a": ClaudeProfile(accountID: "account-a", email: "a@example.com"),
        "access-b": ClaudeProfile(accountID: "account-b", email: "b@example.com"),
        "access-existing": ClaudeProfile(accountID: "account-existing", email: "existing@example.com"),
      ]),
      claudeCredentialLoader: { source in
        claudeCredentials(source: source, payload: payload, registry: registry)
      },
      startsAutomatically: false
    )

    await store.reloadAccounts()

    #expect(registry.load().map(\.id) == ["claude:existing"])
    #expect(store.captureErrors[.claude]?.contains("changed") == true)
  }

  private func waitUntil(
    attempts: Int = 100,
    _ condition: @MainActor () -> Bool
  ) async -> Bool {
    for _ in 0 ..< attempts {
      if condition() {
        return true
      }
      await Task.yield()
    }
    return condition()
  }
}

private struct DuplicateClaudeCaptureFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let selectionStore: ProviderAccountSelectionStore
  let store: UsageStore
}

@MainActor
private func makeDuplicateClaudeCaptureFixture() async throws -> DuplicateClaudeCaptureFixture {
  let directory = try TemporaryDirectory()
  let claudeDirectory = directory.url.appendingPathComponent(".claude", isDirectory: true)
  try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
  let fileURL = claudeDirectory.appendingPathComponent(".credentials.json")
  let keychainPayload = claudePayload(accessToken: "keychain-access", refreshToken: "keychain-refresh")
  try claudePayload(accessToken: "file-access", refreshToken: "file-refresh").write(to: fileURL)
  let payload = AutomaticCapturePayloadBox(keychainPayload)
  let registry = CapturedAccountStore.inMemoryForTesting()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { payload.value },
    capturedAccounts: registry
  )
  let fileAccount = try #require(
    await discovery.accounts(for: .claude).first {
      if case .claudeCredentialsFile = $0.credentialSource {
        return true
      }
      return false
    }
  )
  let selectionStore = ProviderAccountSelectionStore(
    url: directory.url.appendingPathComponent("selection.json")
  )
  try selectionStore.save([.claude: fileAccount])
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountSelectionStore: selectionStore,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "claude-account",
      email: "claude@example.com"
    ),
    claudeCredentialLoader: { source in
      claudeCredentials(source: source, payload: payload, registry: registry)
    },
    startsAutomatically: false
  )
  return DuplicateClaudeCaptureFixture(
    directory: directory,
    registry: registry,
    selectionStore: selectionStore,
    store: store
  )
}

private struct RotatingClaudeCaptureFixture {
  let directory: TemporaryDirectory
  let payload: AutomaticCapturePayloadBox
  let registry: CapturedAccountStore
  let store: UsageStore
}

@MainActor
private func makeRotatingClaudeCaptureFixture() throws -> RotatingClaudeCaptureFixture {
  let directory = try TemporaryDirectory()
  let payload = AutomaticCapturePayloadBox(
    claudePayload(
      accessToken: "access-a",
      refreshToken: "refresh-a",
      expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
  )
  let registry = CapturedAccountStore.inMemoryForTesting()
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { payload.value },
    capturedAccounts: registry
  )
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload.value }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "claude-account",
      email: "claude@example.com"
    ),
    profileStore: ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json")),
    claudeCredentialLoader: { source in
      claudeCredentials(source: source, payload: payload, registry: registry)
    },
    startsAutomatically: false
  )
  return RotatingClaudeCaptureFixture(
    directory: directory,
    payload: payload,
    registry: registry,
    store: store
  )
}

private func claudeCredentials(
  source: ProviderCredentialSource,
  payload: AutomaticCapturePayloadBox,
  registry: CapturedAccountStore
) -> ClaudeCredentials? {
  switch source {
  case .claudeKeychain:
    try? ClaudeCredentialsStore.parse(payload.value)
  case let .claudeCredentialsFile(path):
    (try? Data(contentsOf: URL(fileURLWithPath: path)))
      .flatMap { try? ClaudeCredentialsStore.parse($0) }
  case let .quotariRegistry(id):
    registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
  case .codexAuthFile, .codexKeychain, .claudeEnvironment:
    nil
  }
}
