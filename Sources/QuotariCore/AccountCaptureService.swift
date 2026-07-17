import CryptoKit
import Foundation

public enum AccountCaptureError: LocalizedError, Sendable {
  case sourceNotCapturable
  case payloadUnavailable
  case noRefreshToken
  case credentialChanged

  public var errorDescription: String? {
    switch self {
    case .sourceNotCapturable:
      "This account's credentials can't be saved (only file- or keychain-backed logins)."
    case .payloadUnavailable:
      "Couldn't read the account's credentials to save them."
    case .noRefreshToken:
      "This login has no refresh token, so a saved copy couldn't renew itself once it expires."
    case .credentialChanged:
      "The CLI account changed while Quotari was identifying it. Scan accounts again."
    }
  }
}

/// Snapshots a live account's raw credential bytes into the Quotari-owned
/// registry so it survives the CLI credential slot being reused by another
/// login. This is the "save" half of multi-account support; switching the
/// live credential back is a separate concern.
public struct AccountCaptureService: Sendable {
  let capturedAccounts: CapturedAccountStore
  private let claudeKeychainRead: @Sendable (String) -> Data?
  private let codexKeychainRead: @Sendable (String, String) -> Data?

  public init(
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    claudeKeychainRead: (@Sendable (String) -> Data?)? = nil,
    codexKeychainRead: (@Sendable (String, String) -> Data?)? = nil
  ) {
    self.capturedAccounts = capturedAccounts
    self.claudeKeychainRead = claudeKeychainRead ?? { ClaudeCredentialsStore.keychainItem(service: $0) }
    self.codexKeychainRead = codexKeychainRead ?? { service, account in
      try? KeychainItemStore(account: account).read(service: service)
    }
  }

  /// Captures `account` (as currently discovered) into the registry. If an
  /// entry for the same underlying identity already exists it is refreshed in
  /// place, so re-capturing after a re-login updates rather than duplicates.
  @discardableResult
  public func capture(_ account: ProviderAccount, now: Date) throws -> CapturedAccount {
    guard let rawPayload = rawPayload(for: account.credentialSource) else {
      if account.credentialSource.isCaptured {
        throw AccountCaptureError.sourceNotCapturable
      }
      throw AccountCaptureError.payloadUnavailable
    }
    // Store only the provider fields Quotari reads, dropping unrelated secrets
    // the source may hold alongside them (e.g. Claude's mcpOAuth dictionary).
    guard let payload = ProviderCredentialMinimizer.minimize(provider: account.provider, payload: rawPayload) else {
      if ProviderCredentialMinimizer.hasAccessToken(provider: account.provider, payload: rawPayload) {
        // Readable, but not renewable: like env tokens, a snapshot without a
        // refresh token would die at its first expiry — refuse to save it.
        throw AccountCaptureError.noRefreshToken
      }
      throw AccountCaptureError.payloadUnavailable
    }
    let identity = ProviderCredentialIdentity.key(provider: account.provider, payload: payload)
    if account.provider == .codex, account.credentialScopeID != account.id {
      guard let discoveredIdentity = ProviderCredentialIdentity.discoveredAccountIdentity(
        provider: account.provider,
        payload: payload
      ) else { throw AccountCaptureError.credentialChanged }
      let currentAccount = ProviderAccount(
        provider: account.provider,
        displayName: account.displayName,
        detail: account.detail,
        credentialSource: account.credentialSource,
        credentialIdentity: discoveredIdentity
      )
      guard currentAccount.credentialScopeID == account.credentialScopeID else {
        throw AccountCaptureError.credentialChanged
      }
    }
    let id = registryID(provider: account.provider, identity: identity)
    let captured = CapturedAccount(
      id: id,
      provider: account.provider,
      // Re-derive the label from the freshly read payload, not the possibly
      // stale discovery-time metadata: the live login may have changed between
      // discovery and this Save.
      displayName: ProviderCredentialIdentity.displayName(provider: account.provider, payload: payload)
        ?? account.displayName,
      detail: account.detail,
      capturedAt: now,
      origin: account.credentialSource,
      payload: payload
    )
    return try capturedAccounts.upsert(captured) { existing, candidate in
      Self.preferredCredentialSnapshot(existing: existing, candidate: candidate)
    }
  }

  public func remove(id: String) throws {
    try capturedAccounts.remove(id: id)
  }

  /// Saves an already-read raw payload into the registry (minimizing it
  /// first), for callers that must back up the exact bytes they are about to
  /// overwrite — the switch hands those exact bytes here. Returns nil for an
  /// unrenewable or wrong-shaped payload; throws only on a keychain fault.
  @discardableResult
  public func captureRawPayload(
    provider: UsageProvider,
    origin: ProviderCredentialSource,
    payload: Data,
    now: Date,
    claudeOAuthAccount: Data? = nil
  ) throws -> CapturedAccount? {
    // Renewability is the bar; an identity-less (but renewable) login is
    // still saved, under a UUID, exactly as normal Save would.
    guard let minimized = ProviderCredentialMinimizer.minimize(provider: provider, payload: payload) else {
      return nil
    }
    let identity = ProviderCredentialIdentity.key(provider: provider, payload: minimized)
    let id = registryID(provider: provider, identity: identity)
    let captured = CapturedAccount(
      id: id,
      provider: provider,
      displayName: ProviderCredentialIdentity.displayName(provider: provider, payload: minimized)
        ?? Self.defaultDisplayName(for: provider),
      detail: origin.detail,
      capturedAt: now,
      origin: origin,
      payload: minimized,
      claudeOAuthAccount: provider == .claude ? claudeOAuthAccount : nil
    )
    return try capturedAccounts.upsert(captured) { existing, candidate in
      Self.preferredCredentialSnapshot(existing: existing, candidate: candidate)
    }
  }

  /// Refreshes a known saved account from the exact live source that still
  /// represents it. This explicit id is required for Claude: rotating the
  /// refresh token changes its fingerprint, so ordinary capture would create
  /// a second row and leave the original id holding a consumed pair.
  @discardableResult
  public func refreshCapturedAccount(
    id: String,
    provider: UsageProvider,
    payload: Data,
    claudeOAuthAccount: Data? = nil,
    requiresNewerGenerationEvidence: Bool = false
  ) throws -> CapturedAccount {
    guard let existing = capturedAccounts.account(id: id), existing.provider == provider,
          let minimized = ProviderCredentialMinimizer.minimize(provider: provider, payload: payload)
    else { throw AccountCaptureError.payloadUnavailable }
    // Automatic profile matching supplies stable-account proof but does not
    // order two token generations. That path requests a freshness guard; the
    // explicit switch backup path has stronger transaction evidence and keeps
    // its existing replacement behavior. The guarded decision runs inside the
    // mutation lock so a concurrent refresh cannot be overwritten afterward.
    try capturedAccounts.updatePayload(
      id: id,
      claudeOAuthAccount: provider == .claude ? claudeOAuthAccount : nil
    ) { current in
      guard provider == .claude, requiresNewerGenerationEvidence else { return minimized }
      return ProviderCredentialIdentity.claudeCandidateCanReplace(
        storedPayload: current,
        candidatePayload: minimized
      ) ? minimized : current
    }
    guard let refreshed = capturedAccounts.account(id: id) else {
      throw AccountCaptureError.payloadUnavailable
    }
    return refreshed
  }

  private static func defaultDisplayName(for provider: UsageProvider) -> String {
    switch provider {
    case .claude: "Claude Code"
    case .codex: "Codex account"
    }
  }

  /// Removes the saved copy of a live login's identity and returns its
  /// registry id — the deletion path for a saved account whose registry row
  /// is hidden while the same identity is the live CLI login. Only the
  /// identity is needed (the same test that hid the row), so this works even
  /// when the live payload has no refresh token and isn't capturable itself.
  @discardableResult
  public func removeCapturedCopy(of account: ProviderAccount) throws -> String {
    guard let raw = rawPayload(for: account.credentialSource),
          let identity = ProviderCredentialIdentity.key(provider: account.provider, payload: raw)
    else { throw AccountCaptureError.payloadUnavailable }
    let id = registryID(provider: account.provider, identity: identity)
    try capturedAccounts.remove(id: id)
    return id
  }

  /// While a saved identity is also the live CLI login, its registry row is
  /// hidden and Save is suppressed — so the saved copy tracks the live
  /// credential's own token rotations by re-snapshotting the payload whenever
  /// it changes. Complete for Codex (durable account_id identity); best
  /// effort for Claude, whose identity fingerprint follows the refresh token.
  public func syncCapturedCopies(of accounts: [ProviderAccount]) {
    for account in accounts where !account.credentialSource.isCaptured {
      guard let raw = rawPayload(for: account.credentialSource),
            let payload = ProviderCredentialMinimizer.minimize(provider: account.provider, payload: raw),
            let identity = ProviderCredentialIdentity.key(provider: account.provider, payload: payload)
      else { continue }
      let id = registryID(provider: account.provider, identity: identity)
      guard let existing = capturedAccounts.account(id: id), existing.payload != payload else { continue }
      let provider = account.provider
      // Same identity, but slots can be duplicated (default + CODEX_HOME) and
      // a concurrent refresh can land between this read and the write — so the
      // freshness decision runs INSIDE the mutation lock (on the payload
      // stored right now), never letting a stale slot clobber a fresher pair.
      try? capturedAccounts.updatePayload(id: id) { current in
        if let stored = Self.expiry(provider: provider, payload: current),
           let candidate = Self.expiry(provider: provider, payload: payload),
           candidate < stored {
          return current
        }
        return payload
      }
    }
  }

  public func captured() -> [CapturedAccount] {
    capturedAccounts.load()
  }

  func rawPayload(for source: ProviderCredentialSource) -> Data? {
    switch source {
    case let .codexAuthFile(path):
      // Validate through the Codex loader first so its insecure-permissions
      // guard still applies — capture reads the file directly, and we must not
      // snapshot a bearer token out of a group/world-readable auth.json.
      guard (try? CodexCredentialsStore.load(url: URL(fileURLWithPath: path))) != nil else { return nil }
      return try? Data(contentsOf: URL(fileURLWithPath: path))
    case let .codexKeychain(service, account):
      guard let payload = codexKeychainRead(service, account),
            (try? CodexCredentialsStore.parse(payload)) != nil
      else { return nil }
      return payload
    case let .claudeCredentialsFile(path):
      return try? Data(contentsOf: URL(fileURLWithPath: path))
    case let .claudeKeychain(service):
      return claudeKeychainRead(service)
    case .claudeEnvironment:
      // An env token is just an access token — no refresh token to keep it
      // alive, so a snapshot would die at the next expiry. Not capturable.
      return nil
    case let .quotariRegistry(id):
      return capturedAccounts.account(id: id)?.payload
    }
  }

  private func registryID(provider: UsageProvider, identity: String?) -> String {
    if let identity {
      // Preserve legacy UUID ids created before this provider had a fallback
      // credential identity. Re-capture and discovery must converge on the
      // existing row rather than creating a deterministic duplicate.
      if let existing = capturedAccounts.load().first(where: { account in
        account.provider == provider
          && ProviderCredentialIdentity.key(provider: provider, payload: account.payload) == identity
      }) {
        return existing.id
      }
      return "\(provider.rawValue):\(identity)"
    }
    return "\(provider.rawValue):\(UUID().uuidString)"
  }
}

/// A per-account identity derived from a credential payload. Codex normally
/// exposes a durable `account_id`; legacy id-less logins fall back to their
/// renewable refresh-token fingerprint. Claude's payload has no durable id,
/// so its credential identity remains a refresh-token fingerprint; profile
/// identity is verified separately by the app when a rotation must be linked
/// back to a saved registry row.
public enum ProviderCredentialIdentity {
  public static func key(provider: UsageProvider, payload: Data) -> String? {
    switch provider {
    case .codex:
      guard let credentials = try? CodexCredentialsStore.parse(payload) else { return nil }
      return normalized(credentials.accountID)
        ?? normalized(credentials.email)
        ?? credentials.refreshToken.flatMap(codexRefreshIdentity)
    case .claude:
      guard let credentials = try? ClaudeCredentialsStore.parse(payload) else { return nil }
      return claudeIdentity(refreshToken: credentials.refreshToken, accessToken: credentials.accessToken)
    }
  }

  /// The Claude identity fingerprint for a token pair: the refresh token (or
  /// the access token if there's no refresh token) hashed. Stable enough to
  /// dedupe the same login and to detect when a credential slot's underlying
  /// account has changed. Both empty ⇒ no identity.
  public static func claudeIdentity(refreshToken: String?, accessToken: String?) -> String? {
    tokenIdentity(refreshToken: refreshToken, accessToken: accessToken)
  }

  private static func codexRefreshIdentity(_ refreshToken: String) -> String? {
    guard let refreshToken = normalized(refreshToken) else { return nil }
    return "fp:\(fingerprint(refreshToken))"
  }

  private static func tokenIdentity(refreshToken: String?, accessToken: String?) -> String? {
    guard let secret = normalized(refreshToken) ?? normalized(accessToken) else { return nil }
    return "fp:\(fingerprint(secret))"
  }

  public static func displayName(provider: UsageProvider, payload: Data) -> String? {
    switch provider {
    case .codex:
      guard let credentials = try? CodexCredentialsStore.parse(payload) else { return nil }
      return normalized(credentials.email) ?? normalized(credentials.accountID)
    case .claude:
      return nil
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  /// A collision-resistant fingerprint of an arbitrary secret string. Exposed
  /// so callers that need to detect *any* token change (not just the durable
  /// account identity) — e.g. profile-fetch retry eligibility keyed on the
  /// access token — can derive one consistently.
  public static func fingerprint(of value: String) -> String {
    fingerprint(value)
  }

  private static func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Reduces a raw provider credential payload to just the provider's own
/// credential object, dropping unrelated root-level secrets that live beside
/// it (e.g. the `mcpOAuth` tokens for other services in Claude's keychain
/// item, or Codex's root `OPENAI_API_KEY`). The whole provider object is kept
/// verbatim — including the refresh token and refresh metadata a saved account
/// needs to stay renewable — since everything inside it is that provider's own
/// credential data. Wrong-shaped, token-less, or refresh-token-less payloads
/// are rejected: a snapshot that can't renew itself would die at its first
/// expiry, exactly why env tokens aren't capturable either.
public enum ProviderCredentialMinimizer {
  public static func minimize(provider: UsageProvider, payload: Data) -> Data? {
    switch provider {
    case .claude:
      guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
      else { return nil }
      return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    case .codex:
      guard let credentials = try? CodexCredentialsStore.parse(payload),
            credentials.refreshToken != nil,
            let fields = CodexJSONProjector.topLevelFields(payload),
            let tokens = fields["tokens"]
      else { return nil }
      // Codex requires `last_refresh` alongside `tokens` before it will expose
      // the token data. Keep that provider-owned timestamp while still
      // dropping unrelated root secrets such as OPENAI_API_KEY.
      var minimized = ["tokens": tokens]
      if let refreshData = fields["last_refresh"],
         let lastRefresh = try? JSONDecoder().decode(String.self, from: refreshData),
         !lastRefresh.isEmpty {
        minimized["last_refresh"] = refreshData
      }
      return CodexJSONProjector.replacingTopLevelFields(in: Data("{}".utf8), with: minimized)
    }
  }

  /// Whether the payload carries the provider's access token at all — used to
  /// tell "unreadable payload" apart from "readable but not renewable".
  public static func hasAccessToken(provider: UsageProvider, payload: Data) -> Bool {
    switch provider {
    case .claude:
      guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
      else { return false }
      return !accessToken.isEmpty
    case .codex:
      return (try? CodexCredentialsStore.parse(payload)) != nil
    }
  }
}
