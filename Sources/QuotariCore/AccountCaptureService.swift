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
  private let makeUUID: @Sendable () -> UUID

  public init(
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    claudeKeychainRead: (@Sendable (String) -> Data?)? = nil,
    codexKeychainRead: (@Sendable (String, String) -> Data?)? = nil,
    makeUUID: @escaping @Sendable () -> UUID = UUID.init
  ) {
    self.capturedAccounts = capturedAccounts
    self.claudeKeychainRead = claudeKeychainRead ?? { ClaudeCredentialsStore.keychainItem(service: $0) }
    self.codexKeychainRead = codexKeychainRead ?? { service, account in
      try? KeychainItemStore(account: account).read(service: service)
    }
    self.makeUUID = makeUUID
  }

  /// Captures `account` (as currently discovered) into the registry. Codex
  /// rows converge by credential identity. This generic Claude entry point can
  /// only converge an exact credential generation; callers with verified
  /// profile evidence use `captureClaudeAccount` across token rotations.
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
    let id = account.provider == .claude
      ? newClaudeRegistryID()
      : codexRegistryID(identity: identity)
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
    return try upsertCapturedAccount(captured)
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
    claudeOAuthAccount: Data? = nil,
    claudeAccountIdentity: ClaudeAccountIdentity? = nil,
    preserveExistingClaudeOAuthAccount: Bool = false
  ) throws -> CapturedAccount? {
    // Renewability is the bar; an identity-less (but renewable) login is
    // still saved, under a UUID, exactly as normal Save would.
    guard let minimized = ProviderCredentialMinimizer.minimize(provider: provider, payload: payload) else {
      return nil
    }
    let identity = ProviderCredentialIdentity.key(provider: provider, payload: minimized)
    let id = provider == .claude
      ? newClaudeRegistryID()
      : codexRegistryID(identity: identity)
    let captured = CapturedAccount(
      id: id,
      provider: provider,
      displayName: ProviderCredentialIdentity.displayName(provider: provider, payload: minimized)
        ?? Self.defaultDisplayName(for: provider),
      detail: origin.detail,
      capturedAt: now,
      origin: origin,
      payload: minimized,
      claudeOAuthAccount: provider == .claude ? claudeOAuthAccount : nil,
      claudeAccountIdentity: provider == .claude ? claudeAccountIdentity : nil
    )
    return try upsertCapturedAccount(captured) { existing, candidate in
      var resolved = try Self.preferredCredentialSnapshot(existing: existing, candidate: candidate)
      if provider == .claude, preserveExistingClaudeOAuthAccount,
         let existingOAuthAccount = existing.claudeOAuthAccount {
        resolved.claudeOAuthAccount = existingOAuthAccount
      }
      return resolved
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
    claudeAccountIdentity: ClaudeAccountIdentity? = nil,
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
      claudeOAuthAccount: provider == .claude ? claudeOAuthAccount : nil,
      claudeAccountIdentity: provider == .claude ? claudeAccountIdentity : nil
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

  /// While a saved Codex identity is also the live CLI login, its registry row
  /// is hidden and Save is suppressed. Keep that saved copy current by
  /// re-snapshotting a newer payload into the same deterministic Codex row.
  public func syncCapturedCopies(of accounts: [ProviderAccount]) {
    for account in accounts where account.provider == .codex && !account.credentialSource.isCaptured {
      guard let raw = rawPayload(for: account.credentialSource),
            let payload = ProviderCredentialMinimizer.minimize(provider: account.provider, payload: raw),
            let identity = ProviderCredentialIdentity.key(provider: account.provider, payload: payload)
      else { continue }
      let id = codexRegistryID(identity: identity)
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

  private func codexRegistryID(identity: String?) -> String {
    if let identity {
      // Preserve legacy UUID ids created before this provider had a fallback
      // credential identity. Re-capture and discovery must converge on the
      // existing row rather than creating a deterministic duplicate.
      if let existing = capturedAccounts.load().first(where: { account in
        account.provider == .codex
          && ProviderCredentialIdentity.key(provider: .codex, payload: account.payload) == identity
      }) {
        return existing.id
      }
      return "\(UsageProvider.codex.rawValue):\(identity)"
    }
    return "\(UsageProvider.codex.rawValue):\(makeUUID().uuidString.lowercased())"
  }

  private func newClaudeRegistryID() -> String {
    "\(UsageProvider.claude.rawValue):\(makeUUID().uuidString.lowercased())"
  }

  private func upsertCapturedAccount(
    _ candidate: CapturedAccount,
    mergingExisting merge: (CapturedAccount, CapturedAccount) throws -> CapturedAccount = {
      try Self.preferredCredentialSnapshot(existing: $0, candidate: $1)
    }
  ) throws -> CapturedAccount {
    guard candidate.provider == .claude else {
      return try capturedAccounts.upsert(candidate, mergingExisting: merge)
    }
    return try capturedAccounts.upsert(
      candidate,
      matchingExisting: Self.matchesClaudeCaptureIdentity,
      mergingExisting: merge
    )
  }

  private static func matchesClaudeCaptureIdentity(
    existing: CapturedAccount,
    candidate: CapturedAccount
  ) throws -> Bool {
    let existingIdentity = existing.claudeAccountIdentity
    let candidateIdentity = candidate.claudeAccountIdentity
    let existingCredential = ProviderCredentialIdentity.key(provider: .claude, payload: existing.payload)
    let candidateCredential = ProviderCredentialIdentity.key(provider: .claude, payload: candidate.payload)
    let matchesCredential = existingCredential != nil && existingCredential == candidateCredential
    if let existingIdentity, let candidateIdentity {
      guard existingIdentity.isStrong, candidateIdentity.isStrong else {
        return matchesCredential
      }
      if existingIdentity.identifiesSameAccount(as: candidateIdentity) {
        return true
      }
      if matchesCredential {
        throw CapturedAccountStoreError.conflictingClaudeIdentity
      }
      return false
    }
    // A verified identity may backfill a legacy row only when the exact token
    // generation also matches. Different token generations need app-level
    // profile proof that names the existing target id explicitly.
    return matchesCredential
  }
}
