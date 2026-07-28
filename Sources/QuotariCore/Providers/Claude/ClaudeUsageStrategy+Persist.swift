import Foundation
import os

extension ClaudeUsageStrategy {
  /// The stored registry pair rides a refresh token an exchange rotated away
  /// — it can never refresh again, so the pending grant supersedes it no
  /// matter who wrote it.
  func supersede(
    _ pending: ClaudePendingGrant,
    stored: ResolvedClaudeCredentials,
    now: Date
  ) async -> ClaudeRefreshResolution {
    let reapplied = pending.rebased(replacing: stored.credentials.accessToken)
    if let applied = await persisted(reapplied, resolved: stored) {
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
    resolved: ResolvedClaudeCredentials
  ) async -> ClaudeRefreshResolution? {
    var acceptedGrant: ClaudePendingGrant?
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        to: resolved.source
      )
      // The source holds the grant now; any durable copy is obsolete.
      removeDurableGrantIfMatching(pending, source: resolved.source)
      if case .claudeKeychain = resolved.source {
        acceptedGrant = pending
      } else if case .claudeCredentialsFile = resolved.source {
        acceptedGrant = pending
      }
    } catch ClaudeCredentialPersistError.obsoleteRecoveryCleanupPending {
      let authoritative = (try? reloadCredentials(resolved.source)).map {
        ResolvedClaudeCredentials(credentials: $0, source: resolved.source)
      }
      return ClaudeRefreshResolution(resolved: authoritative ?? resolved)
    } catch ClaudeCredentialPersistError.mirrorRecoveryOwnerChanged {
      let authoritative = (try? reloadCredentials(resolved.source)).map {
        ResolvedClaudeCredentials(credentials: $0, source: resolved.source)
      }
      return ClaudeRefreshResolution(resolved: authoritative ?? resolved)
    } catch ClaudeCredentialPersistError.staleSource {
      return nil
    } catch {
      if let persistError = error as? ClaudeCredentialPersistError,
         case .mirrorRecoveryPending = persistError,
         !resolved.source.isCaptured {
        acceptedGrant = pending
      }
      // The refresh already happened server-side, so dropping the fetch
      // wouldn't undo the rotation — continue with the in-memory pair and
      // queue any grant whose consumed refresh token can no longer recover it.
      Self.logger.error("Persisting refreshed tokens failed: \(error.localizedDescription, privacy: .public)")
      await rememberPending(pending, source: resolved.source)
    }
    return ClaudeRefreshResolution(
      resolved: inMemory(resolved, pending.grant),
      // The live source's guarded write accepted this exact generation. The
      // coordinator shares this proof with every joined caller; each verified
      // saved-account link mirrors it after the transaction returns.
      acceptedGrant: acceptedGrant,
      rotatedFromAccessToken: pending.previousAccessToken
    )
  }
}
