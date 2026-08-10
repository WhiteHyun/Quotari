import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

@MainActor
struct UsageStoreAutomaticCaptureMigrationTests {
  @Test func providerReactivationWaitsForAutomaticCapture() async throws {
    let fixture = try makeReactivationCaptureFixture()
    let reload = Task { await fixture.store.reloadAccounts() }
    await Task.yield()
    await fixture.reader.waitUntilReadStarts()

    fixture.store.setProviderEnabled(.claude, enabled: false)
    fixture.store.setProviderEnabled(.claude, enabled: true)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await fixture.strategy.requestCount == 0)

    fixture.reader.resume()
    await reload.value
    await fixture.store.selectionRefreshTasks[.claude]?.value

    // Unattributed OAuth must not suppress the explicit monitored-row refresh.
    #expect(await fixture.strategy.requestCount == 2)
    #expect(fixture.registry.load().count == 1)
  }

  @Test func reloadMigratesCachedLiveClaudeProfileToSavedAccount() async throws {
    let fixture = try makeCachedProfileMigrationFixture()

    await fixture.store.reloadAccounts()

    let savedProfile = try #require(fixture.store.claudeProfiles[fixture.savedAccountID])
    #expect(savedProfile.accountID == "claude-account")
    #expect(savedProfile.email == "claude@example.com")
    #expect(savedProfile.fingerprint == ProviderCredentialIdentity.fingerprint(of: "saved-access"))
    #expect(fixture.profileStore.load()[fixture.savedAccountID] == savedProfile)
  }

  @Test func automaticCaptureCopiesCachedProfileIntoNewSavedAccount() async throws {
    let fixture = try await makeCachedProfileCreationFixture()

    await fixture.store.reloadAccounts()

    let saved = try #require(fixture.registry.load().first)
    let savedID = ProviderAccount.id(provider: .claude, source: .quotariRegistry(id: saved.id))
    let profile = try #require(fixture.store.claudeProfiles[savedID])
    #expect(profile.accountID == "claude-account")
    #expect(profile.email == "claude@example.com")
    #expect(profile.fingerprint == ProviderCredentialIdentity.fingerprint(of: "claude-access"))
  }

  @Test func fetchedLiveProfileUsesTheSavedCredentialsFingerprintWhenCopied() async throws {
    let fixture = try makeFetchedProfileCopyFixture()

    await fixture.store.reloadAccounts()
    #expect(await waitUntilProfileCopy {
      fixture.store.claudeProfiles[fixture.savedAccountID] != nil
    })

    let liveProfile = try #require(fixture.store.claudeProfiles[fixture.liveAccountID])
    let savedProfile = try #require(fixture.store.claudeProfiles[fixture.savedAccountID])
    #expect(liveProfile.fingerprint == ProviderCredentialIdentity.fingerprint(of: "live-access"))
    #expect(savedProfile.accountID == liveProfile.accountID)
    #expect(savedProfile.email == liveProfile.email)
    #expect(savedProfile.fingerprint == ProviderCredentialIdentity.fingerprint(of: "saved-access"))
  }
}

private struct FetchedProfileCopyFixture {
  let directory: TemporaryDirectory
  let store: UsageStore
  let liveAccountID: String
  let savedAccountID: String
}

@MainActor
private func makeFetchedProfileCopyFixture() throws -> FetchedProfileCopyFixture {
  let directory = try TemporaryDirectory()
  let livePayload = claudePayload(accessToken: "live-access", refreshToken: "shared-refresh")
  let savedPayload = claudePayload(accessToken: "saved-access", refreshToken: "shared-refresh")
  let registry = CapturedAccountStore.inMemoryForTesting()
  let registryID = "claude:fetched-profile-copy"
  try registry.save(cachedProfileMigrationAccount(id: registryID, payload: savedPayload))
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { livePayload },
    capturedAccounts: registry
  )
  let liveAccountID = ProviderAccount.id(
    provider: .claude,
    source: .claudeKeychain(service: ClaudeCredentialsStore.keychainService)
  )
  let savedAccountID = ProviderAccount.id(
    provider: .claude,
    source: .quotariRegistry(id: registryID)
  )
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "claude-account",
      email: "claude@example.com"
    ),
    profileStore: ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json")),
    claudeCredentialLoader: { source in
      switch source {
      case .claudeKeychain:
        try? ClaudeCredentialsStore.parse(livePayload)
      case let .quotariRegistry(id):
        registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
      case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
        nil
      }
    },
    startsAutomatically: false
  )
  return FetchedProfileCopyFixture(
    directory: directory,
    store: store,
    liveAccountID: liveAccountID,
    savedAccountID: savedAccountID
  )
}

@MainActor
private func waitUntilProfileCopy(_ condition: () -> Bool) async -> Bool {
  for _ in 0 ..< 100 {
    if condition() {
      return true
    }
    await Task.yield()
  }
  return condition()
}

private struct ReactivationCaptureFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let reader: BlockingClaudeCaptureReader
  let strategy: ReactivationCaptureStrategy
  let store: UsageStore
}

@MainActor
private func makeReactivationCaptureFixture() throws -> ReactivationCaptureFixture {
  let directory = try TemporaryDirectory()
  let payload = claudePayload(accessToken: "claude-access", refreshToken: "claude-refresh")
  let registry = CapturedAccountStore.inMemoryForTesting()
  let reader = BlockingClaudeCaptureReader(payload: payload)
  let strategy = ReactivationCaptureStrategy()
  let descriptor = ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in [strategy] }
  )
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { payload },
    capturedAccounts: registry
  )
  let store = UsageStore.isolatedForTesting(
    providers: [descriptor],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in reader.read() }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: StableClaudeProfileFetcher(
      accountID: "reactivation-account",
      email: "reactivation@example.com"
    ),
    claudeCredentialLoader: { source in
      automaticCaptureClaudeCredentials(source: source, keychainPayload: reader.read(), registry: registry)
    },
    startsAutomatically: false
  )
  return ReactivationCaptureFixture(
    directory: directory,
    registry: registry,
    reader: reader,
    strategy: strategy,
    store: store
  )
}

private final class BlockingClaudeCaptureReader: @unchecked Sendable {
  private let payload: Data
  private let signal = CaptureReadSignal()
  private let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var shouldBlock = true

  init(payload: Data) {
    self.payload = payload
  }

  func read() -> Data? {
    let blocks = lock.withLock {
      defer { shouldBlock = false }
      return shouldBlock
    }
    if blocks {
      signal.markStarted()
      release.wait()
    }
    return payload
  }

  func waitUntilReadStarts() async {
    await signal.waitUntilStarted()
  }

  func resume() {
    release.signal()
  }
}

private final class CaptureReadSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    let pending = lock.withLock {
      started = true
      defer { waiters.removeAll() }
      return waiters
    }
    pending.forEach { $0.resume() }
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      let resumesImmediately = lock.withLock {
        guard !started else { return true }
        waiters.append(continuation)
        return false
      }
      if resumesImmediately {
        continuation.resume()
      }
    }
  }
}

private actor ReactivationCaptureStrategy: ProviderFetchStrategy {
  nonisolated let id = "reactivation-capture-gate"
  nonisolated let kind = ProviderFetchKind.oauth
  private(set) var requestCount = 0

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    requestCount += 1
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Reactivated"
    )
  }
}

private struct CachedProfileCreationFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let store: UsageStore
}

@MainActor
private func makeCachedProfileCreationFixture() async throws -> CachedProfileCreationFixture {
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
  let profileStore = ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json"))
  try profileStore.save([
    live.id: ClaudeProfile(
      accountID: "claude-account",
      email: "claude@example.com",
      organizationID: "claude-organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "claude-access")
    ),
  ])
  let store = UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in payload }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileStore: profileStore,
    claudeCredentialLoader: { source in
      automaticCaptureClaudeCredentials(source: source, keychainPayload: payload, registry: registry)
    },
    startsAutomatically: false
  )
  return CachedProfileCreationFixture(directory: directory, registry: registry, store: store)
}

private struct CachedProfileMigrationFixture {
  let directory: TemporaryDirectory
  let store: UsageStore
  let profileStore: ClaudeProfileStore
  let savedAccountID: String
}

@MainActor
private func makeCachedProfileMigrationFixture() throws -> CachedProfileMigrationFixture {
  let directory = try TemporaryDirectory()
  let livePayload = claudePayload(accessToken: "live-access", refreshToken: "shared-refresh")
  let savedPayload = claudePayload(accessToken: "saved-access", refreshToken: "shared-refresh")
  let registry = CapturedAccountStore.inMemoryForTesting()
  let registryID = "claude:legacy-saved"
  try registry.save(cachedProfileMigrationAccount(id: registryID, payload: savedPayload))
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: directory.url,
    keychainData: { livePayload },
    capturedAccounts: registry
  )
  let live = ProviderAccount(
    provider: .claude,
    displayName: "Claude Code",
    detail: "Keychain",
    credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    credentialIdentity: "live-access"
  )
  let savedAccountID = ProviderAccount.id(
    provider: .claude,
    source: .quotariRegistry(id: registryID)
  )
  let profileStore = ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json"))
  try profileStore.save([
    live.id: ClaudeProfile(
      accountID: "claude-account",
      email: "claude@example.com",
      organizationID: "claude-organization",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: "live-access")
    ),
  ])
  let store = cachedProfileMigrationStore(
    discovery: discovery,
    profileStore: profileStore,
    livePayload: livePayload,
    registry: registry
  )
  return CachedProfileMigrationFixture(
    directory: directory,
    store: store,
    profileStore: profileStore,
    savedAccountID: savedAccountID
  )
}

private func cachedProfileMigrationAccount(id: String, payload: Data) -> CapturedAccount {
  CapturedAccount(
    id: id,
    provider: .claude,
    displayName: "Saved Claude",
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: 0),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: payload
  )
}

@MainActor
private func cachedProfileMigrationStore(
  discovery: ProviderAccountDiscovery,
  profileStore: ClaudeProfileStore,
  livePayload: Data,
  registry: CapturedAccountStore
) -> UsageStore {
  UsageStore.isolatedForTesting(
    providers: [claudeDescriptorForAutomaticCapture()],
    accountDiscovery: discovery,
    profileStore: profileStore,
    claudeCredentialLoader: { source in
      automaticCaptureClaudeCredentials(source: source, keychainPayload: livePayload, registry: registry)
    },
    startsAutomatically: false
  )
}
