import Foundation

extension CodexUsageStrategy {
  func recordLifecycle(
    _ kind: CredentialLifecycleEvent.Kind,
    registryID: String,
    reason: CredentialLifecycleEvent.Reason? = nil,
    failure: CredentialLifecycleEvent.Failure? = nil,
    timestamp: Date? = nil
  ) {
    credentialLifecycleLogger.record(
      kind,
      provider: .codex,
      source: .quotariRegistry(id: registryID),
      reason: reason,
      failure: failure,
      timestamp: timestamp
    )
  }

  func recordRefreshSelection(
    registryID: String,
    denied: Bool,
    hasPendingGrant: Bool,
    timestamp: Date
  ) {
    if hasPendingGrant {
      recordLifecycle(.pendingGrantFound, registryID: registryID, reason: .pendingGrant, timestamp: timestamp)
    }
    let reason: CredentialLifecycleEvent.Reason = if denied {
      .unauthorized
    } else if hasPendingGrant {
      .pendingGrant
    } else {
      .expired
    }
    recordLifecycle(.refreshSelected, registryID: registryID, reason: reason, timestamp: timestamp)
  }
}
