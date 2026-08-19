import Foundation
import os

extension ClaudeUsageStrategy {
  /// The stored registry pair rides a refresh token an exchange rotated away
  /// — it can never refresh again, so the pending grant supersedes it no
  /// matter who wrote it.
  func supersede(
    _ pending: ClaudePendingGrant,
    stored: ResolvedClaudeCredentials,
    now: Date,
    correlationSource: ProviderCredentialSource? = nil
  ) async -> ClaudeRefreshResolution {
    let reapplied = pending.rebased(replacing: stored.credentials.accessToken)
    if let applied = await persisted(
      reapplied,
      resolved: stored,
      correlationSource: correlationSource
    ) {
      guard let installed = try? ClaudeCredentialsStore.load(
        source: stored.source,
        capturedAccounts: capturedAccounts
      ), pending.matchesInstalledGeneration(
        accessToken: installed.accessToken,
        refreshToken: installed.refreshToken
      ) else {
        // `persisted` also returns the in-memory grant after a transient write
        // failure. Keep the original durable owner until the source proves it
        // accepted the rebased grant.
        return applied
      }
      removeDurableGrantIfMatching(pending, source: stored.source)
      return ClaudeRefreshResolution(
        resolved: applied.resolved,
        acceptedGrant: stored.source.isCaptured ? nil : pending,
        // The rebased write only changes the compare-and-swap owner. The
        // refresh still rotated from the pending grant's original token, so
        // carry that token's cooldown into the installed generation.
        rotatedFromAccessToken: pending.previousAccessToken
      )
    }
    // Yet another concurrent write landed; at some point theirs is the truth.
    return ClaudeRefreshResolution(
      resolved: reloadedFromSource(stored, now: now) ?? inMemory(stored, pending.grant)
    )
  }

  /// Persists the pending grant and returns the credentials to fetch with,
  /// or nil when the source holds a different pair than the grant replaces.
  /// A write failure keeps a consumed rotating grant queued for retry and
  /// still returns it: the rotation already happened server-side, so the
  /// in-memory pair is the freshest one there is.
  func persisted(
    _ pending: ClaudePendingGrant,
    resolved: ResolvedClaudeCredentials,
    correlationSource: ProviderCredentialSource? = nil
  ) async -> ClaudeRefreshResolution? {
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        to: resolved.source
      )
      return successfulPersistenceResolution(
        pending,
        resolved: resolved,
        correlationSource: correlationSource
      )
    } catch ClaudeCredentialPersistError.obsoleteRecoveryCleanupPending {
      return deferredPersistenceResolution(resolved, correlationSource: correlationSource)
    } catch ClaudeCredentialPersistError.mirrorRecoveryOwnerChanged {
      return deferredPersistenceResolution(resolved, correlationSource: correlationSource)
    } catch ClaudeCredentialPersistError.staleSource {
      recordLifecycle(
        .persistenceDeferred,
        source: resolved.source,
        correlationSource: correlationSource,
        reason: .concurrentCredentialChange,
        failure: .staleSource
      )
      return nil
    } catch {
      return await failedPersistenceResolution(
        error,
        pending: pending,
        resolved: resolved,
        correlationSource: correlationSource
      )
    }
  }

  private func successfulPersistenceResolution(
    _ pending: ClaudePendingGrant,
    resolved: ResolvedClaudeCredentials,
    correlationSource: ProviderCredentialSource?
  ) -> ClaudeRefreshResolution {
    recordLifecycle(
      .persistenceSucceeded,
      source: resolved.source,
      correlationSource: correlationSource
    )
    removeDurableGrantIfMatching(pending, source: resolved.source)
    let acceptedGrant: ClaudePendingGrant? = switch resolved.source {
    case .claudeKeychain, .claudeCredentialsFile: pending
    default: nil
    }
    return persistenceResolution(pending, resolved: resolved, acceptedGrant: acceptedGrant)
  }

  private func deferredPersistenceResolution(
    _ resolved: ResolvedClaudeCredentials,
    correlationSource: ProviderCredentialSource?
  ) -> ClaudeRefreshResolution {
    recordLifecycle(
      .persistenceDeferred,
      source: resolved.source,
      correlationSource: correlationSource,
      reason: .concurrentCredentialChange
    )
    let authoritative = (try? reloadCredentials(resolved.source)).map {
      ResolvedClaudeCredentials(credentials: $0, source: resolved.source)
    }
    return ClaudeRefreshResolution(resolved: authoritative ?? resolved)
  }

  private func failedPersistenceResolution(
    _ error: Error,
    pending: ClaudePendingGrant,
    resolved: ResolvedClaudeCredentials,
    correlationSource: ProviderCredentialSource?
  ) async -> ClaudeRefreshResolution {
    let acceptedGrant: ClaudePendingGrant? = if let persistError = error as? ClaudeCredentialPersistError,
                                                case .mirrorRecoveryPending = persistError,
                                                !resolved.source.isCaptured {
      pending
    } else {
      nil
    }
    Self.logger.error("Persisting refreshed tokens failed: \(error.localizedDescription, privacy: .public)")
    recordLifecycle(
      .persistenceFailed,
      source: resolved.source,
      correlationSource: correlationSource,
      failure: .persistence
    )
    await rememberPending(pending, source: resolved.source)
    return persistenceResolution(pending, resolved: resolved, acceptedGrant: acceptedGrant)
  }

  private func persistenceResolution(
    _ pending: ClaudePendingGrant,
    resolved: ResolvedClaudeCredentials,
    acceptedGrant: ClaudePendingGrant?
  ) -> ClaudeRefreshResolution {
    ClaudeRefreshResolution(
      resolved: inMemory(resolved, pending.grant),
      // The coordinator shares this accepted-generation proof with joined
      // callers so every verified saved-account link can mirror it.
      acceptedGrant: acceptedGrant,
      rotatedFromAccessToken: pending.previousAccessToken
    )
  }
}
