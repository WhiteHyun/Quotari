import Foundation

extension ClaudeUsageStrategy {
  func recordLifecycle(
    _ kind: CredentialLifecycleEvent.Kind,
    source: ProviderCredentialSource,
    reason: CredentialLifecycleEvent.Reason? = nil,
    failure: CredentialLifecycleEvent.Failure? = nil,
    timestamp: Date? = nil
  ) {
    credentialLifecycleLogger.record(
      kind,
      provider: .claude,
      source: source,
      reason: reason,
      failure: failure,
      timestamp: timestamp
    )
  }

  func recordRefreshSelection(
    source: ProviderCredentialSource,
    denied: Bool,
    hasPendingGrant: Bool,
    timestamp: Date
  ) {
    let reason: CredentialLifecycleEvent.Reason = if denied {
      .unauthorized
    } else if hasPendingGrant {
      .pendingGrant
    } else {
      .expired
    }
    recordLifecycle(.refreshSelected, source: source, reason: reason, timestamp: timestamp)
  }
}
