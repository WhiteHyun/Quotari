import Foundation
@testable import Quotari
@testable import QuotariCore
import Testing

/// A scriptable profile fetcher: the handler maps the access token to an
/// outcome (and may suspend, to model an in-flight fetch), and calls are
/// counted, so tests can drive success, auth failure, transient failure, and
/// mid-flight credential rotation.
final class ScriptedProfileFetcher: ClaudeProfileFetching, @unchecked Sendable {
  enum Outcome { case email(String); case unauthorized; case transient }

  private let lock = NSLock()
  private var storage = 0
  private let handler: @Sendable (String) async -> Outcome

  init(_ handler: @escaping @Sendable (String) async -> Outcome) {
    self.handler = handler
  }

  convenience init(email: String) {
    self.init { _ in .email(email) }
  }

  var count: Int {
    lock.withLock { storage }
  }

  func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
    lock.withLock { storage += 1 }
    switch await handler(accessToken) {
    case let .email(email): return ClaudeProfile(email: email)
    case .unauthorized: throw ProviderHTTPError.unauthorized
    case .transient: throw ProviderHTTPError.status(503)
    }
  }
}

/// An async gate a test can hold closed to keep a fetch in flight, then open.
final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false

  func open() {
    lock.withLock { opened = true }
  }

  func wait() async {
    while !lock.withLock({ opened }) {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

@MainActor
// Profile fetch, cache, and identity matching share the same scripted fixtures.
// swiftlint:disable:next type_body_length
struct UsageStoreProfileTests {
  private static let claudeProviders = MockProviders.descriptors.filter { $0.id == .claude }

  private static func claudeAccount() -> ProviderAccount {
    ProviderAccount(
      provider: .claude, displayName: "Claude Code", detail: "Keychain",
      credentialSource: .claudeKeychain(service: "Claude Code-credentials")
    )
  }

  private func makeStore(
    fetcher: ScriptedProfileFetcher,
    accessToken: @escaping @Sendable () -> String
  ) -> UsageStore {
    UsageStore.isolatedForTesting(
      providers: Self.claudeProviders,
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [Self.claudeAccount()]]),
      profileFetcher: fetcher,
      profileStore: .temporaryForTesting(),
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: accessToken(), refreshToken: "ref") },
      startsAutomatically: false
    )
  }

  @Test func labelsClaudeAccountByFetchedEmailAndFetchesOnce() async throws {
    let fetcher = ScriptedProfileFetcher(email: "dev@example.com")
    let store = makeStore(fetcher: fetcher) { "access-1" }

    await store.reloadAccounts()
    try await waitFor { fetcher.count == 1 }
    try await waitFor { store.accountLabel(for: Self.claudeAccount()) == "dev@example.com" }

    // A second reload with the same token must not re-hit the endpoint.
    await store.reloadAccounts()
    try await Task.sleep(for: .milliseconds(100))
    #expect(fetcher.count == 1)
  }

  @Test func refetchesWhenTheAccessTokenRotates() async throws {
    // Same account, access-token-only rotation (refresh token unchanged): the
    // access-token fingerprint changes, so the label self-heals with one fetch.
    let fetcher = ScriptedProfileFetcher(email: "dev@example.com")
    let box = TokenBox(token: "access-1")
    let store = makeStore(fetcher: fetcher) { box.value }

    await store.reloadAccounts()
    try await waitFor { fetcher.count == 1 }

    box.value = "access-2"
    await store.reloadAccounts()
    try await waitFor { fetcher.count == 2 }
  }

  @Test func droppedStaleEmailWhenReusedSlotIsADifferentAccount() async throws {
    // Account A is cached; the slot is re-logged-in as a different account
    // (different durable identity) whose token is denied. The old email must
    // not keep showing.
    let access = TokenBox(token: "acc-A")
    let refresh = TokenBox(token: "ref-A")
    let fetcher = ScriptedProfileFetcher { token in
      token == "acc-A" ? .email("a@example.com") : .unauthorized
    }
    let store = UsageStore.isolatedForTesting(
      providers: Self.claudeProviders,
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [Self.claudeAccount()]]),
      profileFetcher: fetcher,
      profileStore: .temporaryForTesting(),
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: access.value, refreshToken: refresh.value) },
      startsAutomatically: false
    )

    await store.reloadAccounts()
    try await waitFor { store.accountLabel(for: Self.claudeAccount()) == "a@example.com" }

    access.value = "acc-B" // different account in the same slot
    refresh.value = "ref-B"
    await store.reloadAccounts()
    try await waitFor { store.accountLabel(for: Self.claudeAccount()) == "Claude Code" }
  }

  @Test func rotationDuringAnInFlightFetchEndsOnTheNewAccountsEmail() async throws {
    // token "acc-A" hangs until released; "acc-B" returns immediately. The
    // credential rotates A→B while A's fetch is suspended; the resolver must
    // end up showing B's email, not A's stale write.
    let gate = Gate()
    let fetcher = ScriptedProfileFetcher { token in
      if token == "acc-A" {
        await gate.wait()
        return .email("a@example.com")
      }
      return .email("b@example.com")
    }
    let box = TokenBox(token: "acc-A")
    let store = makeStore(fetcher: fetcher) { box.value }

    await store.reloadAccounts() // starts A's fetch, which blocks on the gate
    try await waitFor { fetcher.count == 1 }

    box.value = "acc-B" // rotate while A is in flight
    gate.open() // let A complete; the resolver loop should then fetch B

    try await waitFor { store.accountLabel(for: Self.claudeAccount()) == "b@example.com" }
  }

  @Test func transientFailureIsRetriedOnTheNextReload() async throws {
    let failing = TokenBox(token: "yes")
    let fetcher = ScriptedProfileFetcher { _ in
      failing.value == "yes" ? .transient : .email("dev@example.com")
    }
    let store = makeStore(fetcher: fetcher) { "access-1" }

    await store.reloadAccounts()
    try await waitFor { fetcher.count == 1 }
    // Still no label — the fetch failed transiently.
    #expect(store.accountLabel(for: Self.claudeAccount()) == "Claude Code")

    // A transient failure isn't negatively cached: the same token retries.
    failing.value = "no"
    await store.reloadAccounts()
    try await waitFor { store.accountLabel(for: Self.claudeAccount()) == "dev@example.com" }
  }

  private func seededStore(
    profile: ClaudeProfile,
    liveAccessToken: String,
    fetcher: ScriptedProfileFetcher
  ) throws -> UsageStore {
    let profileStore = ClaudeProfileStore.temporaryForTesting()
    try profileStore.save([Self.claudeAccount().id: profile])
    return UsageStore.isolatedForTesting(
      providers: Self.claudeProviders,
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [Self.claudeAccount()]]),
      profileFetcher: fetcher,
      profileStore: profileStore,
      claudeCredentialLoader: { _ in ClaudeCredentials(accessToken: liveAccessToken, refreshToken: "ref") },
      startsAutomatically: false
    )
  }

  @Test func rotatedTokenKeepsTheEmailThroughATransientFailure() async throws {
    // Access token rotated and the confirming fetch fails transiently: the
    // cached email must stay (no flicker on a routine rotation / brief outage).
    let store = try seededStore(
      profile: ClaudeProfile(
        email: "keep@example.com",
        fingerprint: ProviderCredentialIdentity.fingerprint(of: "acc-1")
      ),
      liveAccessToken: "acc-2",
      fetcher: ScriptedProfileFetcher { _ in .transient }
    )

    await store.reloadAccounts()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.accountLabel(for: Self.claudeAccount()) == "keep@example.com")
  }

  @Test func rotatedTokenThatIsDeniedDropsTheStaleEmail() async throws {
    // The token rotated to one the endpoint denies (a likely account change):
    // the cached email from the old token is dropped.
    let store = try seededStore(
      profile: ClaudeProfile(
        email: "old@example.com",
        fingerprint: ProviderCredentialIdentity.fingerprint(of: "acc-1")
      ),
      liveAccessToken: "acc-2",
      fetcher: ScriptedProfileFetcher { _ in .unauthorized }
    )

    await store.reloadAccounts()
    try await waitFor { store.accountLabel(for: Self.claudeAccount()) == "Claude Code" }
  }

  @Test func verifiedAccountUUIDIdentifiesTheRotatedLiveTargetBeforeEmail() async throws {
    let outcome = try await switchOutcome(
      savedAccountID: "account-uuid",
      savedEmail: "old-address@example.com",
      liveAccountID: "account-uuid",
      liveEmail: "new-address@example.com",
      liveProfileAccessToken: "live-access"
    )

    #expect(outcome.savedAccessToken == "live-access")
    #expect(outcome.capturedCount == 1)
  }

  @Test func verifiedEmailIdentifiesTheRotatedLiveTargetWhenUUIDIsUnavailable() async throws {
    let outcome = try await switchOutcome(
      savedAccountID: nil,
      savedEmail: "Dev@Example.com",
      liveAccountID: nil,
      liveEmail: "dev@example.com",
      liveProfileAccessToken: "live-access"
    )

    #expect(outcome.savedAccessToken == "live-access")
    #expect(outcome.capturedCount == 1)
  }

  @Test func staleProfileFingerprintCannotIdentifyTheLiveTarget() async throws {
    let outcome = try await switchOutcome(
      savedAccountID: "account-uuid",
      savedEmail: "dev@example.com",
      liveAccountID: "account-uuid",
      liveEmail: "dev@example.com",
      liveProfileAccessToken: "stale-access"
    )

    // The unverified profile is ignored. The live login is preserved as its
    // own saved row instead of being mistaken for a fresher copy of the target.
    #expect(outcome.savedAccessToken == "saved-access")
    #expect(outcome.capturedCount == 2)
  }

  @Test func fallsBackToDisplayNameWithoutAProfile() {
    let store = UsageStore.isolatedForTesting(
      providers: Self.claudeProviders,
      startsAutomatically: false
    )
    #expect(store.accountLabel(for: Self.claudeAccount()) == "Claude Code")
  }

  // Keep the registry row, live keychain, and verified profiles together so assertions cannot drift from setup.
  // swiftlint:disable:next function_body_length
  private func switchOutcome(
    savedAccountID: String?,
    savedEmail: String,
    liveAccountID: String?,
    liveEmail: String,
    liveProfileAccessToken: String
  ) async throws -> SwitchOutcome {
    let directory = try TemporaryDirectory()
    let registry = CapturedAccountStore.inMemoryForTesting()
    let savedRegistryID = "claude:legacy-saved"
    let savedPayload = Data(
      #"{"claudeAiOauth":{"accessToken":"saved-access","refreshToken":"saved-refresh"}}"#.utf8
    )
    let livePayload = Data(
      #"{"claudeAiOauth":{"accessToken":"live-access","refreshToken":"live-refresh"}}"#.utf8
    )
    try registry.save(CapturedAccount(
      id: savedRegistryID,
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      capturedAt: Date(timeIntervalSince1970: 1000),
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: savedPayload
    ))
    let savedAccount = ProviderAccount(
      provider: .claude,
      displayName: "Saved Claude",
      detail: "Saved in Quotari",
      credentialSource: .quotariRegistry(id: savedRegistryID)
    )
    let liveAccount = Self.claudeAccount()
    let profileStore = ClaudeProfileStore.temporaryForTesting()
    try profileStore.save([
      savedAccount.id: ClaudeProfile(
        accountID: savedAccountID,
        email: savedEmail,
        fingerprint: ProviderCredentialIdentity.fingerprint(of: "saved-access")
      ),
      liveAccount.id: ClaudeProfile(
        accountID: liveAccountID,
        email: liveEmail,
        fingerprint: ProviderCredentialIdentity.fingerprint(of: liveProfileAccessToken)
      ),
    ])
    let keychain = PayloadBox(livePayload)
    let store = UsageStore.isolatedForTesting(
      providers: Self.claudeProviders,
      accountDiscovery: StaticAccountDiscovery(accounts: [.claude: [savedAccount, liveAccount]]),
      accountSwitch: .isolatedForTesting(
        capturedAccounts: registry,
        home: directory.url,
        keychainRead: { _ in keychain.value },
        keychainWrite: { payload, _ in keychain.value = payload }
      ),
      profileStore: profileStore,
      claudeCredentialLoader: { source in
        let payload: Data? = switch source {
        case let .quotariRegistry(id): registry.account(id: id)?.payload
        case .claudeKeychain: keychain.value
        default: nil
        }
        return payload.flatMap { try? ClaudeCredentialsStore.parse($0) }
      },
      startsAutomatically: false
    )
    await store.reloadAccounts()

    await store.switchCLIAccount(to: savedAccount)

    let saved = try #require(registry.account(id: savedRegistryID))
    let credentials = try ClaudeCredentialsStore.parse(saved.payload)
    return SwitchOutcome(
      savedAccessToken: credentials.accessToken,
      capturedCount: registry.load().count
    )
  }

  private func waitFor(_ condition: () -> Bool, attempts: Int = 40) async throws {
    for _ in 0 ..< attempts {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(condition())
  }

  private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String
    init(token: String) {
      storage = token
    }

    var value: String {
      get { lock.withLock { storage } }
      set { lock.withLock { storage = newValue } }
    }
  }

  private struct SwitchOutcome {
    var savedAccessToken: String
    var capturedCount: Int
  }

  private final class PayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data

    init(_ value: Data) {
      storage = value
    }

    var value: Data {
      get { lock.withLock { storage } }
      set { lock.withLock { storage = newValue } }
    }
  }
}
