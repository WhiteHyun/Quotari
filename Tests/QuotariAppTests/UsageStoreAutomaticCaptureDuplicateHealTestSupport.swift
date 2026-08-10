import Foundation
@testable import Quotari
@testable import QuotariCore

@MainActor
struct DuplicateHealReloadFixture {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let store: UsageStore
  let selectionStore: ProviderAccountSelectionStore
  let monitoringStore: ProviderAccountMonitoringStore
  let canonicalID: String
  let redundantID: String
  let redundantProviderID: String
}

@MainActor
func makeDuplicateHealReloadFixture(
  canonicalAlreadyLive: Bool,
  allowsCanonicalRefresh: Bool = true,
  usesPersistedIdentityWithoutProfileCache: Bool = false,
  hasMalformedSelectionConfiguration: Bool = false
) throws -> DuplicateHealReloadFixture {
  let options = DuplicateHealReloadOptions(
    canonicalAlreadyLive: canonicalAlreadyLive,
    allowsCanonicalRefresh: allowsCanonicalRefresh,
    usesPersistedIdentityWithoutProfileCache: usesPersistedIdentityWithoutProfileCache
  )
  let state = try duplicateHealReloadState(options: options)
  let registry = state.registry
  let selectionStore = ProviderAccountSelectionStore(
    url: state.directory.url.appendingPathComponent("selection.json")
  )
  let monitoringStore = ProviderAccountMonitoringStore(
    url: state.directory.url.appendingPathComponent("monitoring.json")
  )
  if hasMalformedSelectionConfiguration {
    try Data("not-json".utf8).write(to: selectionStore.url)
  } else {
    try selectionStore.save([.claude: state.redundant.providerAccount])
  }
  try monitoringStore.save([.claude: [state.redundant.providerAccount]])
  let store = duplicateHealReloadUsageStore(
    state: state,
    options: options,
    selectionStore: selectionStore,
    monitoringStore: monitoringStore
  )
  return DuplicateHealReloadFixture(
    directory: state.directory,
    registry: registry,
    store: store,
    selectionStore: selectionStore,
    monitoringStore: monitoringStore,
    canonicalID: state.canonical.id,
    redundantID: state.redundant.id,
    redundantProviderID: state.redundant.providerAccount.id
  )
}

private struct DuplicateHealReloadOptions {
  let canonicalAlreadyLive: Bool
  let allowsCanonicalRefresh: Bool
  let usesPersistedIdentityWithoutProfileCache: Bool
}

private struct DuplicateHealReloadState {
  let directory: TemporaryDirectory
  let registry: CapturedAccountStore
  let canonical: CapturedAccount
  let redundant: CapturedAccount
  let livePayload: Data
  let profile: ClaudeProfile
  let profileStore: ClaudeProfileStore
}

private struct DuplicateHealReloadRows {
  let canonical: CapturedAccount
  let redundant: CapturedAccount
}

private func duplicateHealReloadState(
  options: DuplicateHealReloadOptions
) throws -> DuplicateHealReloadState {
  let directory = try TemporaryDirectory()
  let registry = CapturedAccountStore.inMemoryForTesting()
  let livePayload = options.allowsCanonicalRefresh
    ? claudePayload(
      accessToken: "live-access",
      refreshToken: "live-refresh",
      expiresAt: Date().addingTimeInterval(3600)
    )
    : claudePayload(accessToken: "live-access", refreshToken: "live-refresh")
  let deadCanonicalPayload = claudePayload(
    accessToken: "canonical-dead-access",
    refreshToken: "canonical-dead-refresh",
    expiresAt: Date(timeIntervalSince1970: 0)
  )
  let profile = ClaudeProfile(
    accountID: "account",
    email: "same@example.com",
    organizationID: "organization"
  )
  let persistedIdentity = options.usesPersistedIdentityWithoutProfileCache
    ? profile.accountIdentity
    : nil
  let rows = duplicateHealReloadRows(
    livePayload: livePayload,
    deadCanonicalPayload: deadCanonicalPayload,
    identity: persistedIdentity,
    canonicalAlreadyLive: options.canonicalAlreadyLive
  )
  try registry.save(rows.canonical)
  try registry.save(rows.redundant)
  let profileStore = try duplicateHealReloadProfileStore(
    directory: directory,
    rows: rows,
    profile: profile,
    options: options
  )
  return DuplicateHealReloadState(
    directory: directory,
    registry: registry,
    canonical: rows.canonical,
    redundant: rows.redundant,
    livePayload: livePayload,
    profile: profile,
    profileStore: profileStore
  )
}

private func duplicateHealReloadRows(
  livePayload: Data,
  deadCanonicalPayload: Data,
  identity: ClaudeAccountIdentity?,
  canonicalAlreadyLive: Bool
) -> DuplicateHealReloadRows {
  DuplicateHealReloadRows(
    canonical: duplicateHealAccount(
      id: "claude:canonical",
      name: "Canonical",
      capturedAt: 200,
      payload: canonicalAlreadyLive ? livePayload : deadCanonicalPayload,
      identity: identity
    ),
    redundant: duplicateHealAccount(
      id: "claude:redundant",
      name: "Redundant",
      capturedAt: 100,
      payload: claudePayload(
        accessToken: "redundant-dead-access",
        refreshToken: "redundant-dead-refresh",
        expiresAt: Date(timeIntervalSince1970: 0)
      ),
      identity: identity
    )
  )
}

private func duplicateHealReloadProfileStore(
  directory: TemporaryDirectory,
  rows: DuplicateHealReloadRows,
  profile: ClaudeProfile,
  options: DuplicateHealReloadOptions
) throws -> ClaudeProfileStore {
  let store = ClaudeProfileStore(url: directory.url.appendingPathComponent("profiles.json"))
  guard !options.usesPersistedIdentityWithoutProfileCache else { return store }
  try store.save([
    rows.canonical.providerAccount.id: profile.verified(for: ProviderCredentialIdentity.fingerprint(
      of: options.canonicalAlreadyLive ? "live-access" : "canonical-dead-access"
    )),
    rows.redundant.providerAccount.id: profile.verified(
      for: ProviderCredentialIdentity.fingerprint(of: "redundant-dead-access")
    ),
  ])
  return store
}

@MainActor
private func duplicateHealReloadUsageStore(
  state: DuplicateHealReloadState,
  options: DuplicateHealReloadOptions,
  selectionStore: ProviderAccountSelectionStore,
  monitoringStore: ProviderAccountMonitoringStore
) -> UsageStore {
  let livePayload = state.livePayload
  let registry = state.registry
  let discovery = ProviderAccountDiscovery(
    environment: [:],
    home: state.directory.url,
    keychainData: { livePayload },
    capturedAccounts: registry
  )
  let reauthenticationRequiredIDs: Set<String> = options.canonicalAlreadyLive
    ? [state.redundant.id]
    : [state.canonical.id, state.redundant.id]
  return UsageStore.isolatedForTesting(
    providers: [duplicateHealDescriptor(reauthenticationRequiredIDs: reauthenticationRequiredIDs)],
    accountDiscovery: discovery,
    accountSelectionStore: selectionStore,
    accountMonitoringStore: monitoringStore,
    accountCapture: AccountCaptureService(
      capturedAccounts: registry,
      claudeKeychainRead: { _ in livePayload }
    ),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: ["live-access": state.profile]),
    profileStore: state.profileStore,
    claudeCredentialLoader: duplicateHealCredentialLoader(
      registry: registry,
      livePayload: livePayload
    ),
    startsAutomatically: false
  )
}

private func duplicateHealAccount(
  id: String,
  name: String,
  capturedAt: TimeInterval,
  payload: Data,
  identity: ClaudeAccountIdentity? = nil
) -> CapturedAccount {
  CapturedAccount(
    id: id,
    provider: .claude,
    displayName: name,
    detail: "Saved in Quotari",
    capturedAt: Date(timeIntervalSince1970: capturedAt),
    origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    payload: payload,
    claudeAccountIdentity: identity
  )
}

private func duplicateHealDescriptor(
  reauthenticationRequiredIDs: Set<String>,
  transientFailureIDs: Set<String> = []
) -> ProviderDescriptor {
  ProviderDescriptor(
    id: .claude,
    metadata: ProviderMetadata(
      displayName: "Claude",
      accent: .init(0.8, 0.5, 0.2),
      supportsWeekly: true
    ),
    pipeline: ProviderFetchPipeline { _ in
      [DuplicateHealStrategy(
        reauthenticationRequiredIDs: reauthenticationRequiredIDs,
        transientFailureIDs: transientFailureIDs
      )]
    }
  )
}

private func duplicateHealCredentialLoader(
  registry: CapturedAccountStore,
  livePayload: Data
) -> @Sendable (ProviderCredentialSource) -> ClaudeCredentials? {
  { source in
    switch source {
    case .claudeKeychain:
      try? ClaudeCredentialsStore.parse(livePayload)
    case let .quotariRegistry(id):
      registry.account(id: id).flatMap { try? ClaudeCredentialsStore.parse($0.payload) }
    case .codexAuthFile, .codexKeychain, .claudeEnvironment, .claudeCredentialsFile:
      nil
    }
  }
}

struct SavedRowSpec {
  let id: String
  let token: String
  let capturedAt: Date
  var expiresAt = Date(timeIntervalSince1970: 0)

  var accessToken: String {
    "\(token)-access"
  }

  var refreshToken: String {
    "\(token)-refresh"
  }
}

@MainActor
struct DuplicateHealFixture {
  let registry: CapturedAccountStore
  let store: UsageStore
  let candidate: ProviderAccount
}

/// Every saved row and the live candidate verify to the same profile identity
/// ("acct"), reproducing the duplicate-saved-account state; per-row refresh
/// behavior is driven by the id sets.
@MainActor
func makeDuplicateHealFixture(
  savedRows: [SavedRowSpec],
  reauthenticationRequiredIDs: Set<String>,
  transientFailureIDs: Set<String> = []
) throws -> DuplicateHealFixture {
  let registry = CapturedAccountStore.inMemoryForTesting()
  let profileStore = try duplicateHealProfileStore(
    registry: registry,
    savedRows: savedRows
  )
  let livePayload = claudePayload(
    accessToken: "live-access",
    refreshToken: "live-refresh",
    expiresAt: Date().addingTimeInterval(3600)
  )
  let candidate = ProviderAccount(
    provider: .claude,
    displayName: "Live",
    detail: "Keychain",
    credentialSource: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
    credentialIdentity: "live-access"
  )
  let store = UsageStore.isolatedForTesting(
    providers: [duplicateHealDescriptor(
      reauthenticationRequiredIDs: reauthenticationRequiredIDs,
      transientFailureIDs: transientFailureIDs
    )],
    accountCapture: AccountCaptureService(capturedAccounts: registry),
    automaticallyCapturesDiscoveredAccounts: true,
    profileFetcher: TokenClaudeProfileFetcher(profiles: [
      "live-access": ClaudeProfile(
        accountID: "acct",
        email: "dup@example.com",
        organizationID: "org"
      ),
    ]),
    profileStore: profileStore,
    claudeCredentialLoader: duplicateHealCredentialLoader(
      registry: registry,
      livePayload: livePayload
    ),
    startsAutomatically: false
  )
  return DuplicateHealFixture(registry: registry, store: store, candidate: candidate)
}

private func duplicateHealProfileStore(
  registry: CapturedAccountStore,
  savedRows: [SavedRowSpec]
) throws -> ClaudeProfileStore {
  var pinnedProfiles: [String: ClaudeProfile] = [:]
  for row in savedRows {
    let account = CapturedAccount(
      id: row.id,
      provider: .claude,
      displayName: "Claude Code",
      detail: "Saved in Quotari",
      capturedAt: row.capturedAt,
      origin: .claudeKeychain(service: ClaudeCredentialsStore.keychainService),
      payload: claudePayload(
        accessToken: row.accessToken,
        refreshToken: row.refreshToken,
        expiresAt: row.expiresAt
      )
    )
    try registry.save(account)
    pinnedProfiles[account.providerAccount.id] = ClaudeProfile(
      accountID: "acct",
      email: "dup@example.com",
      organizationID: "org",
      fingerprint: ProviderCredentialIdentity.fingerprint(of: row.accessToken)
    )
  }
  let profileStore = ClaudeProfileStore.temporaryForTesting()
  try profileStore.save(pinnedProfiles)
  return profileStore
}

/// Simulates the OAuth refresh outcome per saved registry row: a definitive
/// invalid grant for dead rows, a transient network failure for undecided
/// rows, and plain usage success otherwise.
private struct DuplicateHealStrategy: ProviderFetchStrategy {
  let id = "duplicate-heal"
  let kind = ProviderFetchKind.oauth
  let reauthenticationRequiredIDs: Set<String>
  let transientFailureIDs: Set<String>

  func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
    if case let .quotariRegistry(registryID) = context.account?.credentialSource {
      if reauthenticationRequiredIDs.contains(registryID) {
        throw ClaudeTokenRefreshError.reauthenticationRequired
      }
      if transientFailureIDs.contains(registryID) {
        throw URLError(.notConnectedToInternet)
      }
    }
    return ProviderFetchResult(
      usage: UsageSnapshot(provider: context.provider, updatedAt: context.now),
      sourceLabel: "Stub"
    )
  }
}
