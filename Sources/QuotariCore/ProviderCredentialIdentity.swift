import CryptoKit
import Foundation

/// A per-account identity derived from a credential payload. Codex normally
/// exposes a durable `account_id`; legacy id-less logins fall back to their
/// renewable refresh-token fingerprint. Claude's value identifies only a
/// credential generation for discovery/CAS. Captured row identity is the
/// separate, token-independent `ClaudeAccountIdentity`.
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

  /// The Claude fingerprint identifies one credential generation, not a
  /// durable registry row. It is used only for discovery and stale-write CAS.
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
  /// so profile caches can bind their evidence to one access-token generation.
  public static func fingerprint(of value: String) -> String {
    fingerprint(value)
  }

  private static func fingerprint(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
