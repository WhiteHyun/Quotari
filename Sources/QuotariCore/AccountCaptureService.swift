import CryptoKit
import Foundation

public enum AccountCaptureError: LocalizedError, Sendable {
  case sourceNotCapturable
  case payloadUnavailable
  case noRefreshToken

  public var errorDescription: String? {
    switch self {
    case .sourceNotCapturable:
      "This account's credentials can't be saved (only file- or keychain-backed logins)."
    case .payloadUnavailable:
      "Couldn't read the account's credentials to save them."
    case .noRefreshToken:
      "This login has no refresh token, so a saved copy couldn't renew itself once it expires."
    }
  }
}

/// Snapshots a live account's raw credential bytes into the Quotari-owned
/// registry so it survives the CLI credential slot being reused by another
/// login. This is the "save" half of multi-account support; switching the
/// live credential back is a separate concern.
public struct AccountCaptureService: Sendable {
  private let capturedAccounts: CapturedAccountStore
  private let claudeKeychainRead: @Sendable (String) -> Data?

  public init(
    capturedAccounts: CapturedAccountStore = CapturedAccountStore(),
    claudeKeychainRead: (@Sendable (String) -> Data?)? = nil
  ) {
    self.capturedAccounts = capturedAccounts
    self.claudeKeychainRead = claudeKeychainRead ?? { ClaudeCredentialsStore.keychainItem(service: $0) }
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
    try capturedAccounts.save(captured)
    return captured
  }

  public func remove(id: String) throws {
    try capturedAccounts.remove(id: id)
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
      // Same identity, but slots can be duplicated (default + CODEX_HOME):
      // never let a stale slot clobber a fresher saved pair.
      if let stored = Self.expiry(provider: account.provider, payload: existing.payload),
         let candidate = Self.expiry(provider: account.provider, payload: payload),
         candidate < stored {
        continue
      }
      try? capturedAccounts.updatePayload(id: id) { _ in payload }
    }
  }

  /// The access-token expiry a payload reports, used to order competing
  /// snapshots of the same identity.
  private static func expiry(provider: UsageProvider, payload: Data) -> Date? {
    switch provider {
    case .codex: (try? CodexCredentialsStore.parse(payload))?.expiresAt
    case .claude: (try? ClaudeCredentialsStore.parse(payload))?.expiresAt
    }
  }

  public func captured() -> [CapturedAccount] {
    capturedAccounts.load()
  }

  private func rawPayload(for source: ProviderCredentialSource) -> Data? {
    switch source {
    case let .codexAuthFile(path):
      // Validate through the Codex loader first so its insecure-permissions
      // guard still applies — capture reads the file directly, and we must not
      // snapshot a bearer token out of a group/world-readable auth.json.
      guard (try? CodexCredentialsStore.load(url: URL(fileURLWithPath: path))) != nil else { return nil }
      return try? Data(contentsOf: URL(fileURLWithPath: path))
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
      return "\(provider.rawValue):\(identity)"
    }
    return "\(provider.rawValue):\(UUID().uuidString)"
  }
}

/// A per-account identity derived from a credential payload. Codex exposes a
/// durable `account_id` (so a re-capture updates the same entry). Claude's
/// payload has no durable account id, so its identity is a fingerprint of the
/// refresh token: stable enough to dedupe the same login immediately after
/// capture and to hide the saved copy while it's the live account, without
/// claiming to survive a server-side refresh-token rotation. (A durable Claude
/// identity via the profile email arrives with PS-135.)
public enum ProviderCredentialIdentity {
  public static func key(provider: UsageProvider, payload: Data) -> String? {
    switch provider {
    case .codex:
      guard let credentials = try? CodexCredentialsStore.parse(payload) else { return nil }
      return normalized(credentials.accountID) ?? normalized(credentials.email)
    case .claude:
      guard let credentials = try? ClaudeCredentialsStore.parse(payload) else { return nil }
      // No durable account id in the payload, so fingerprint the refresh token
      // (fall back to the access token) — stable enough to dedupe the same
      // login now. Both empty ⇒ no identity.
      guard let secret = normalized(credentials.refreshToken) ?? normalized(credentials.accessToken)
      else { return nil }
      return "fp:\(fingerprint(secret))"
    }
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
    guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    switch provider {
    case .claude:
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty
      else { return nil }
      return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    case .codex:
      guard let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
            let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty
      else { return nil }
      return try? JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
    }
  }

  /// Whether the payload carries the provider's access token at all — used to
  /// tell "unreadable payload" apart from "readable but not renewable".
  public static func hasAccessToken(provider: UsageProvider, payload: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
    switch provider {
    case .claude:
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String
      else { return false }
      return !accessToken.isEmpty
    case .codex:
      guard let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String
      else { return false }
      return !accessToken.isEmpty
    }
  }
}
