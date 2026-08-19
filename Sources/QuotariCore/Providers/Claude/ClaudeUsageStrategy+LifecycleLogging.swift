import Foundation
import os

extension ClaudeUsageStrategy {
  enum DurablePendingLifecycleLoad {
    case available(ClaudePendingGrant?)
    case unavailable
  }

  func recordLifecycle(
    _ kind: CredentialLifecycleEvent.Kind,
    source: ProviderCredentialSource,
    correlationSource: ProviderCredentialSource? = nil,
    reason: CredentialLifecycleEvent.Reason? = nil,
    failure: CredentialLifecycleEvent.Failure? = nil,
    timestamp: Date? = nil
  ) {
    credentialLifecycleLogger.record(
      kind,
      provider: .claude,
      source: source,
      correlationSource: correlationSource,
      reason: reason,
      failure: failure,
      timestamp: timestamp
    )
  }

  func recordRefreshSelection(
    source: ProviderCredentialSource,
    correlationSource: ProviderCredentialSource? = nil,
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
    recordLifecycle(
      .refreshSelected,
      source: source,
      correlationSource: correlationSource,
      reason: reason,
      timestamp: timestamp
    )
  }

  func recordLinkedMirrorResult(
    _ result: LinkedMirrorResult,
    registryID: String
  ) {
    let source = ProviderCredentialSource.quotariRegistry(id: registryID)
    switch result {
    case .ready:
      recordLifecycle(
        .persistenceSucceeded,
        source: source,
        correlationSource: source
      )
    case .unrelated:
      recordLifecycle(
        .persistenceDeferred,
        source: source,
        correlationSource: source,
        reason: .concurrentCredentialChange,
        failure: .staleSource
      )
    case .blocked:
      recordLifecycle(
        .persistenceDeferred,
        source: source,
        correlationSource: source,
        failure: .persistence
      )
    }
  }

  func loadDurablePendingForLifecycle(
    resolved: ResolvedClaudeCredentials,
    correlationSource: ProviderCredentialSource?,
    now: Date
  ) -> DurablePendingLifecycleLoad {
    do {
      return try .available(loadDurablePending(source: resolved.source))
    } catch {
      // A read failure is not proof of absence. Exchanging the stored token
      // could consume it while the only issued replacement is unreadable.
      Self.logger.error("Reading a pending Claude grant failed: \(error.localizedDescription, privacy: .public)")
      recordLifecycle(
        .pendingGrantReadFailed,
        source: resolved.source,
        correlationSource: correlationSource,
        failure: .inputOutput,
        timestamp: now
      )
      return .unavailable
    }
  }
}
