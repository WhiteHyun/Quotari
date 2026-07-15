import Foundation

public extension AccountCaptureService {
  /// Captures the exact Claude payload whose access token established the
  /// stable profile match. Reading and validating once prevents a replaced
  /// slot from receiving the previous login's profile.
  @discardableResult
  func captureClaudeAccount(
    _ account: ProviderAccount,
    expectedAccessTokenFingerprint: String,
    now: Date
  ) throws -> CapturedAccount {
    guard account.provider == .claude,
          !account.credentialSource.isCaptured,
          let rawPayload = rawPayload(for: account.credentialSource),
          let credentials = try? ClaudeCredentialsStore.parse(rawPayload),
          ProviderCredentialIdentity.fingerprint(of: credentials.accessToken) == expectedAccessTokenFingerprint
    else { throw AccountCaptureError.credentialChanged }
    guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
      throw AccountCaptureError.noRefreshToken
    }
    guard let captured = try captureRawPayload(
      provider: .claude,
      origin: account.credentialSource,
      payload: rawPayload,
      now: now
    ) else { throw AccountCaptureError.payloadUnavailable }
    return captured
  }

  /// Refreshes a captured Claude row from a live source only when the source
  /// still contains the access token whose profile established the stable
  /// account match. The source is read exactly once before the registry write,
  /// so a concurrent CLI relogin cannot redirect a verified match to another
  /// account.
  @discardableResult
  func refreshCapturedClaudeAccount(
    id: String,
    from account: ProviderAccount,
    expectedAccessTokenFingerprint: String
  ) throws -> CapturedAccount {
    guard account.provider == .claude,
          !account.credentialSource.isCaptured,
          let rawPayload = rawPayload(for: account.credentialSource),
          let credentials = try? ClaudeCredentialsStore.parse(rawPayload),
          ProviderCredentialIdentity.fingerprint(of: credentials.accessToken) == expectedAccessTokenFingerprint
    else { throw AccountCaptureError.credentialChanged }
    return try refreshCapturedAccount(
      id: id,
      provider: .claude,
      payload: rawPayload,
      requiresNewerGenerationEvidence: true
    )
  }
}

public extension ProviderCredentialIdentity {
  /// Stable profile identity proves that two Claude payloads belong to the
  /// same account, but not which rotating token pair is newer. A shared
  /// refresh token proves an access-only rotation; otherwise both explicit
  /// expiries must order the candidate after the saved generation.
  static func claudeCandidateCanReplace(
    storedPayload: Data,
    candidatePayload: Data
  ) -> Bool {
    guard let stored = try? ClaudeCredentialsStore.parse(storedPayload),
          let candidate = try? ClaudeCredentialsStore.parse(candidatePayload)
    else { return false }
    if let storedRefresh = normalized(stored.refreshToken),
       storedRefresh == normalized(candidate.refreshToken) {
      return true
    }
    guard let storedExpiry = stored.expiresAt,
          let candidateExpiry = candidate.expiresAt
    else { return false }
    return candidateExpiry > storedExpiry
  }

  /// The raw identity discovery supplies to `ProviderAccount`. This differs
  /// from the registry key for fallback identities: `ProviderAccount` applies
  /// its own fingerprint, so feeding it an already-hashed registry key would
  /// produce a different credential scope for the same login.
  static func discoveredAccountIdentity(provider: UsageProvider, payload: Data) -> String? {
    switch provider {
    case .codex:
      guard let credentials = try? CodexCredentialsStore.parse(payload) else { return nil }
      return normalized(credentials.accountID)
        ?? normalized(credentials.email)
        ?? normalized(credentials.refreshToken)
        ?? normalized(credentials.accessToken)
    case .claude:
      guard let credentials = try? ClaudeCredentialsStore.parse(payload) else { return nil }
      return normalized(credentials.accessToken)
    }
  }

  private static func normalized(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}
