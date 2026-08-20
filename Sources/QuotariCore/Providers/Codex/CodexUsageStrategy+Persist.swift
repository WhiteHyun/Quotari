import Foundation
import os

extension CodexUsageStrategy {
  struct PersistedGrant {
    let credentials: CodexCredentials
    let isDurablyRecoverable: Bool
  }

  /// Persists the pending grant and returns the credentials to fetch with,
  /// or nil when the registry holds a different pair than the grant replaces
  /// (someone re-captured or refreshed concurrently — their pair wins). A
  /// write failure keeps the grant queued for retry and still returns it:
  /// the rotation already happened server-side, so the in-memory pair is the
  /// freshest one there is.
  func persisted(
    _ pending: CodexPendingGrant,
    credentials: CodexCredentials,
    registryID: String,
    now: Date
  ) async -> PersistedGrant? {
    do {
      try persister.persist(
        pending.grant,
        replacing: pending.previousAccessToken,
        toRegistryAccount: registryID
      )
      recordLifecycle(.persistenceSucceeded, registryID: registryID)
      // The registry holds the grant now; any durable copy is obsolete.
      removePendingIfMatching(pending, registryID: registryID)
    } catch CodexCredentialPersistError.staleSource {
      recordLifecycle(
        .persistenceDeferred,
        registryID: registryID,
        reason: .concurrentCredentialChange,
        failure: .staleSource
      )
      return nil
    } catch {
      Self.logger.error("Persisting refreshed Codex tokens failed: \(error.localizedDescription, privacy: .public)")
      recordLifecycle(.persistenceFailed, registryID: registryID, failure: .persistence)
      let isDurablyRecoverable = await rememberPending(pending, registryID: registryID)
      // The write failed, so the registry still holds the old (possibly
      // denied) pair — the in-memory grant is the only fresh one.
      return PersistedGrant(
        credentials: inMemory(credentials, pending.grant),
        isDurablyRecoverable: isDurablyRecoverable
      )
    }
    // Re-read for the fully derived fields (JWT expiry, id_token email); fall
    // back to patching in memory when the registry read fails.
    return PersistedGrant(
      credentials: reloadedFromRegistry(id: registryID, now: now) ?? inMemory(credentials, pending.grant),
      isDurablyRecoverable: true
    )
  }
}
