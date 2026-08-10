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
  ) throws -> CapturedAccount {
    var resolved: CapturedAccount
    if let storedExpiry = expiry(provider: existing.provider, payload: existing.payload),
       let candidateExpiry = expiry(provider: candidate.provider, payload: candidate.payload),
       candidateExpiry < storedExpiry {
      resolved = existing
    } else if candidate.claudeOAuthAccount != nil {
      resolved = candidate
    } else {
      var candidate = candidate
      candidate.claudeOAuthAccount = existing.claudeOAuthAccount
      resolved = candidate
    }
    switch (existing.claudeAccountIdentity, candidate.claudeAccountIdentity) {
    case let (stored?, incoming?):
      guard let merged = stored.merged(with: incoming) else {
        throw CapturedAccountStoreError.conflictingClaudeIdentity
      }
      resolved.claudeAccountIdentity = merged
    case let (stored?, nil):
      resolved.claudeAccountIdentity = stored
    case let (nil, incoming?):
      resolved.claudeAccountIdentity = incoming
    case (nil, nil):
      break
    }
    return resolved
  }
}
