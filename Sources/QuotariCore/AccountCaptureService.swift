import CryptoKit
import Foundation

public enum AccountCaptureError: LocalizedError, Sendable {
  case sourceNotCapturable
  case payloadUnavailable

  public var errorDescription: String? {
    switch self {
    case .sourceNotCapturable:
      "This account's credentials can't be saved (only file- or keychain-backed logins)."
    case .payloadUnavailable:
      "Couldn't read the account's credentials to save them."
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
/// credential data. Wrong-shaped or token-less payloads are rejected.
public enum ProviderCredentialMinimizer {
  public static func minimize(provider: UsageProvider, payload: Data) -> Data? {
    guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    switch provider {
    case .claude:
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty
      else { return nil }
      return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    case .codex:
      guard let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
      else { return nil }
      return try? JSONSerialization.data(withJSONObject: ["tokens": tokens], options: [.sortedKeys])
    }
  }
}
