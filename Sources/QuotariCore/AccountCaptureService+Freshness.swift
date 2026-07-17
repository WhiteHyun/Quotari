import Foundation

extension AccountCaptureService {
  /// The access-token expiry a payload reports, used to order competing
  /// snapshots of the same identity.
  static func expiry(provider: UsageProvider, payload: Data) -> Date? {
    switch provider {
    case .codex: (try? CodexCredentialsStore.parse(payload))?.expiresAt
    case .claude: (try? ClaudeCredentialsStore.parse(payload))?.expiresAt
    }
  }

  static func preferredCredentialSnapshot(
    existing: CapturedAccount,
    candidate: CapturedAccount
  ) -> CapturedAccount {
    if let storedExpiry = expiry(provider: existing.provider, payload: existing.payload),
       let candidateExpiry = expiry(provider: candidate.provider, payload: candidate.payload),
       candidateExpiry < storedExpiry {
      return existing
    }
    guard candidate.claudeOAuthAccount == nil else { return candidate }
    var resolved = candidate
    resolved.claudeOAuthAccount = existing.claudeOAuthAccount
    return resolved
  }
}
