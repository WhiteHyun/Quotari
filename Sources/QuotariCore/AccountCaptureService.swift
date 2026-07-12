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
    case let .codexAuthFile(path), let .claudeCredentialsFile(path):
      try? Data(contentsOf: URL(fileURLWithPath: path))
    case let .claudeKeychain(service):
      claudeKeychainRead(service)
    case .claudeEnvironment:
      // An env token is just an access token — no refresh token to keep it
      // alive, so a snapshot would die at the next expiry. Not capturable.
      nil
    case let .quotariRegistry(id):
      capturedAccounts.account(id: id)?.payload
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

/// Reduces a raw provider credential payload to only the fields Quotari's
/// parsers read, so a captured snapshot never carries unrelated secrets (e.g.
/// the mcpOAuth tokens that live alongside Claude's OAuth in the same keychain
/// item) and never stores a wrong-shaped or unusable blob.
public enum ProviderCredentialMinimizer {
  public static func minimize(provider: UsageProvider, payload: Data) -> Data? {
    guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
    switch provider {
    case .claude:
      guard let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty
      else { return nil }
      var minimal: [String: Any] = ["accessToken": accessToken]
      copyString("refreshToken", from: oauth, into: &minimal)
      copyString("subscriptionType", from: oauth, into: &minimal)
      copyString("rateLimitTier", from: oauth, into: &minimal)
      if let expiresAt = oauth["expiresAt"] as? NSNumber {
        minimal["expiresAt"] = expiresAt
      }
      if let scopes = oauth["scopes"] as? [String] {
        minimal["scopes"] = scopes
      }
      return try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": minimal], options: [.sortedKeys])
    case .codex:
      guard let tokens = root["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
      else { return nil }
      var minimal: [String: Any] = ["access_token": accessToken]
      copyString("account_id", from: tokens, into: &minimal)
      copyString("id_token", from: tokens, into: &minimal)
      return try? JSONSerialization.data(withJSONObject: ["tokens": minimal], options: [.sortedKeys])
    }
  }

  /// Copies `key` only when it's a String, so a type-confused value under an
  /// allowed key can't ride along into the stored snapshot.
  private static func copyString(_ key: String, from source: [String: Any], into target: inout [String: Any]) {
    if let value = source[key] as? String {
      target[key] = value
    }
  }
}
