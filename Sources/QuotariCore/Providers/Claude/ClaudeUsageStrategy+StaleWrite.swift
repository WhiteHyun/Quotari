import Foundation

extension ClaudeUsageStrategy {
  enum StaleWriteResolution {
    case resolved(ClaudeRefreshResolution)
    /// The stored pair is the entered generation and provably still
    /// exchangeable — either it was never consumed, or its exchange showed
    /// the endpoint keeps the token alive.
    case exchange(ResolvedClaudeCredentials)
  }

  /// The source was rewritten while a refreshed pair was in hand (its guarded
  /// write was rejected as stale). A pair still riding the token this exchange
  /// rotated away is superseded by the grant; a different login/generation is
  /// authoritative and makes the queued grant obsolete.
  func resolvedStaleWrite(
    _ pending: ClaudePendingGrant,
    enteredWith refreshToken: String,
    fallback: ResolvedClaudeCredentials,
    now: Date,
    correlationSource: ProviderCredentialSource?
  ) async -> StaleWriteResolution {
    guard let current = try? ClaudeCredentialsStore.load(
      source: fallback.source,
      capturedAccounts: capturedAccounts
    ) else {
      return await unreadablePendingResolution(pending, fallback: fallback)
    }
    let stored = ResolvedClaudeCredentials(credentials: current, source: fallback.source)
    if pending.matchesInstalledGeneration(
      accessToken: current.accessToken,
      refreshToken: current.refreshToken
    ) {
      removeDurableGrantIfMatching(pending, source: fallback.source)
      return .resolved(ClaudeRefreshResolution(
        resolved: stored,
        acceptedGrant: fallback.source.isCaptured ? nil : pending,
        rotatedFromAccessToken: pending.previousAccessToken
      ))
    }
    if pending.supersedes(
      accessToken: current.accessToken,
      refreshToken: current.refreshToken
    ) {
      return await .resolved(supersede(
        pending,
        stored: stored,
        now: now,
        correlationSource: correlationSource
      ))
    }
    // The grant is obsolete on the remaining paths — clear any durable copy
    // so it isn't retried (against a pair that has moved on) every launch.
    removeDurableGrantIfMatching(pending, source: fallback.source)
    guard current.isExpired(now: now) else {
      return .resolved(ClaudeRefreshResolution(
        resolved: stored,
        rotatedFromAccessToken: current.refreshToken == refreshToken
          ? pending.previousAccessToken
          : nil
      ))
    }
    if current.refreshToken != refreshToken {
      return await .resolved(refreshResolutionIfExpired(
        stored,
        now: now,
        capturedRegistryID: capturedRegistryID(in: correlationSource)
      ))
    }
    return .exchange(stored)
  }

  private func unreadablePendingResolution(
    _ pending: ClaudePendingGrant,
    fallback: ResolvedClaudeCredentials
  ) async -> StaleWriteResolution {
    // The grant may hold the only refresh token that still works, so keep it
    // queued for the next transaction and fetch with it in the meantime.
    await rememberPending(pending, source: fallback.source)
    return .resolved(ClaudeRefreshResolution(
      resolved: inMemory(fallback, pending.grant),
      rotatedFromAccessToken: pending.previousAccessToken
    ))
  }

  private func capturedRegistryID(
    in correlationSource: ProviderCredentialSource?
  ) -> String? {
    if case let .quotariRegistry(id) = correlationSource {
      return id
    }
    return nil
  }
}
