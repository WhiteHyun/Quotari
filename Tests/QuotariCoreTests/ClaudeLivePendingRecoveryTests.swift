import Foundation
@testable import QuotariCore
import Testing

private let liveRecoveryNow = Date(timeIntervalSince1970: 2000)

private func livePendingGrant(
  accessToken: String = "new-tok",
  refreshToken: String = "ref-2"
) -> ClaudePendingGrant {
  ClaudePendingGrant(
    grant: ClaudeTokenGrant(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: Date(timeIntervalSince1970: 100_000)
    ),
    previousAccessToken: "old-tok",
    consumedRefreshToken: "ref-1"
  )
}

private func livePendingStore(_ label: String) -> CapturedAccountStore {
  CapturedAccountStore(
    keychain: InMemoryKeychain().store,
    service: "Test-ClaudeLive-\(label)-\(UUID().uuidString)"
  )
}

private func fileResolver(
  source: ProviderCredentialSource,
  store: CapturedAccountStore
) -> @Sendable () throws -> ResolvedClaudeCredentials {
  {
    try ResolvedClaudeCredentials(
      credentials: ClaudeCredentialsStore.load(source: source, capturedAccounts: store),
      source: source
    )
  }
}

private func keychainResolver(
  source: ProviderCredentialSource,
  slot: KeychainSlot
) -> @Sendable () throws -> ResolvedClaudeCredentials {
  {
    guard let payload = slot.value else { throw ClaudeCredentialPersistError.sourceUnavailable }
    return try ResolvedClaudeCredentials(
      credentials: ClaudeCredentialsStore.parse(payload),
      source: source
    )
  }
}

private func keychainWriter(
  slot: KeychainSlot,
  store: CapturedAccountStore
) -> ClaudeCredentialsWriter {
  ClaudeCredentialsWriter(
    keychainRead: { _ in slot.value },
    keychainWrite: { data, _ in slot.value = data },
    capturedAccounts: store
  )
}

private func liveStrategy(
  resolve: @escaping @Sendable () throws -> ResolvedClaudeCredentials,
  refresher: any ClaudeTokenRefreshing,
  persister: (any ClaudeCredentialPersisting)? = nil,
  store: CapturedAccountStore,
  coordinator: ClaudeTokenRefreshCoordinator = ClaudeTokenRefreshCoordinator(),
  recorder: RefreshStubTransport.Recorder? = nil
) -> ClaudeUsageStrategy {
  ClaudeUsageStrategy(
    transport: RefreshStubTransport(json: usageJSON, recorder: recorder),
    resolveCredentials: resolve,
    refresher: refresher,
    persister: persister,
    capturedAccounts: store,
    refreshCoordinator: coordinator
  )
}

private func fetchLive(_ strategy: ClaudeUsageStrategy) async throws {
  _ = try await strategy.fetch(ProviderFetchContext(provider: .claude, now: liveRecoveryNow))
}

struct ClaudeLivePendingRecoveryTests {
  @Test func aRotatedFileGrantSurvivesRelaunchWithoutAnotherExchange() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-live-recovery-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000).write(to: url)
    let source = ProviderCredentialSource.claudeCredentialsFile(path: url.path)
    let store = livePendingStore("File")
    let resolver = fileResolver(source: source, store: store)
    let firstRefresher = StubRefresher(result: .success(livePendingGrant().grant))
    let firstLaunch = liveStrategy(
      resolve: resolver,
      refresher: firstRefresher,
      persister: FlakyClaudePersister(inner: ClaudeCredentialsWriter(), failures: 1),
      store: store
    )

    try await fetchLive(firstLaunch)
    #expect(try firstLaunch.loadDurablePending(source: source) == livePendingGrant())

    let secondRefresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let secondLaunch = liveStrategy(resolve: resolver, refresher: secondRefresher, store: store)
    try await fetchLive(secondLaunch)

    #expect(firstRefresher.calls == ["ref-1"])
    #expect(secondRefresher.calls.isEmpty)
    #expect(try secondLaunch.loadDurablePending(source: source) == nil)
    let stored = try ClaudeCredentialsStore.load(source: source, capturedAccounts: store)
    #expect(stored.accessToken == "new-tok")
    #expect(stored.refreshToken == "ref-2")
  }

  @Test func aRotatedKeychainGrantSurvivesRelaunchWithoutAnotherExchange() async throws {
    let slot = KeychainSlot(
      claudePayload(accessToken: "old-tok", refreshToken: "ref-1", expiresAt: 1000)
    )
    let source = ProviderCredentialSource.claudeKeychain(service: "Test-Claude-Code")
    let store = livePendingStore("Keychain")
    let resolver = keychainResolver(source: source, slot: slot)
    let writer = keychainWriter(slot: slot, store: store)
    let firstRefresher = StubRefresher(result: .success(livePendingGrant().grant))
    let firstLaunch = liveStrategy(
      resolve: resolver,
      refresher: firstRefresher,
      persister: FlakyClaudePersister(inner: writer, failures: 1),
      store: store
    )

    try await fetchLive(firstLaunch)
    #expect(try firstLaunch.loadDurablePending(source: source) == livePendingGrant())

    let secondRefresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let secondLaunch = liveStrategy(
      resolve: resolver,
      refresher: secondRefresher,
      persister: writer,
      store: store
    )
    try await fetchLive(secondLaunch)

    #expect(firstRefresher.calls == ["ref-1"])
    #expect(secondRefresher.calls.isEmpty)
    #expect(try secondLaunch.loadDurablePending(source: source) == nil)
    let stored = try ClaudeCredentialsStore.parse(#require(slot.value))
    #expect(stored.accessToken == "new-tok")
    #expect(stored.refreshToken == "ref-2")
  }

  @Test func aFreshExternalReloginDiscardsRatherThanAppliesThePendingGrant() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-live-relogin-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try claudePayload(accessToken: "relogin-tok", refreshToken: "relogin-ref", expiresAt: 100_000)
      .write(to: url)
    let source = ProviderCredentialSource.claudeCredentialsFile(path: url.path)
    let store = livePendingStore("Relogin")
    let seed = liveStrategy(
      resolve: fileResolver(source: source, store: store),
      refresher: StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse)),
      store: store
    )
    await seed.rememberPending(livePendingGrant(), source: source)
    let recorder = RefreshStubTransport.Recorder()
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let relaunched = liveStrategy(
      resolve: fileResolver(source: source, store: store),
      refresher: refresher,
      store: store,
      recorder: recorder
    )

    try await fetchLive(relaunched)

    #expect(refresher.calls.isEmpty)
    #expect(try relaunched.loadDurablePending(source: source) == nil)
    let stored = try ClaudeCredentialsStore.load(source: source, capturedAccounts: store)
    #expect(stored.accessToken == "relogin-tok")
    #expect(stored.refreshToken == "relogin-ref")
    #expect(recorder.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer relogin-tok")
  }

  @Test func anAlreadyInstalledGrantClearsItsPendingCopyWithoutAnExchange() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-live-installed-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try claudePayload(accessToken: "new-tok", refreshToken: "ref-2", expiresAt: 100_000).write(to: url)
    let source = ProviderCredentialSource.claudeCredentialsFile(path: url.path)
    let store = livePendingStore("Installed")
    let seed = liveStrategy(
      resolve: fileResolver(source: source, store: store),
      refresher: StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse)),
      store: store
    )
    await seed.rememberPending(livePendingGrant(), source: source)
    let refresher = StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse))
    let relaunched = liveStrategy(
      resolve: fileResolver(source: source, store: store),
      refresher: refresher,
      store: store
    )

    try await fetchLive(relaunched)

    #expect(refresher.calls.isEmpty)
    #expect(try relaunched.loadDurablePending(source: source) == nil)
    let stored = try ClaudeCredentialsStore.load(source: source, capturedAccounts: store)
    #expect(stored.accessToken == "new-tok")
    #expect(stored.refreshToken == "ref-2")
  }

  @Test func aCompetingLivePendingGrantKeepsOwnership() async throws {
    let source = ProviderCredentialSource.claudeCredentialsFile(path: "/tmp/claude-owner.json")
    let store = livePendingStore("Ownership")
    let coordinator = ClaudeTokenRefreshCoordinator()
    let strategy = liveStrategy(
      resolve: {
        ResolvedClaudeCredentials(
          credentials: ClaudeCredentials(accessToken: "old-tok", refreshToken: "ref-1"),
          source: source
        )
      },
      refresher: StubRefresher(result: .failure(ClaudeTokenRefreshError.malformedResponse)),
      store: store,
      coordinator: coordinator
    )
    let owner = livePendingGrant()
    let competitor = livePendingGrant(accessToken: "other-tok", refreshToken: "other-ref")

    await strategy.rememberPending(owner, source: source)
    await strategy.rememberPending(competitor, source: source)

    #expect(try strategy.loadDurablePending(source: source) == owner)
    #expect(await coordinator.takeUnpersisted(sourceID: source.stableID) == owner)
  }
}
